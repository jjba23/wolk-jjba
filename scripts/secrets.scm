;;;; wolk-jjba

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; wolk-jjba is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; wolk-jjba is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with wolk-jjba.  If not, see <https://www.gnu.org/licenses/>.

;; Commentary:
;;
;; `maak secrets' -- the half of the secrets contract that runs on the
;; machine a human sits at (the other half is (wolk-jjba secrets), which
;; runs on the server).
;;
;;   list                 what is here, and what the machine has
;;   set NAME             encrypt a value for NAME (hidden prompt, or
;;                        stdin when piped), then push it
;;   edit NAME            open the decrypted value in $EDITOR, re-encrypt,
;;                        then push -- for the secrets that are not one line
;;   get NAME             print the decrypted value
;;   push [NAME...]       push every secret (or the ones named) to the
;;                        machine and apply them there
;;   apply                only run the machine's secrets-apply job
;;   keygen               create the GPG key the secrets are encrypted to
;;
;; Shape of the whole thing:
;;
;;   ~/.config/wolk-jjba/secrets/<name>.gpg     the source of truth, one
;;                                              GPG file per secret, 0600,
;;                                              never in git;
;;   /etc/secrets/<name>                        the canonical copy on the
;;                                              machine, root-only, 0600;
;;   derived files                              written by the machine from
;;                                              the canonical copy (see
;;                                              (wolk-jjba secrets)).
;;
;; Nothing is decrypted to disk on the way: `gpg --decrypt' writes into a
;; pipe that goes straight into `ssh ... install /dev/stdin', so the
;; plaintext leaves the GnuPG agent and lands on the machine's root-only
;; file without a temporary copy on either machine, and without a token in
;; a command line, a shell history or `ps'.  The one exception is `edit',
;; where the file is the point: it lives in a 0700 directory under
;; XDG_RUNTIME_DIR (tmpfs, not the disk) and is removed when the editor
;; exits, whether it succeeded or not.
;;
;; Encryption is public-key by default: the secrets are encrypted to the
;; author's own key, so decrypting them is the GnuPG agent's job and a
;; human only has to unlock the key once in a while (see `gpg-agent's
;; default-cache-ttl').  `recipients' in that directory, one key id per
;; line, replaces the default key -- that is how a second machine, or a
;; colleague, gets a copy.
;;
;; This file is plain Guile plus gpg, ssh and an editor, so `maak secrets'
;; can run it anywhere: it imports (wolk-jjba secrets) for the names of
;; the registries and the path convention, and nothing from Guix.
;;
;; Code:

(use-modules (ice-9 format)
             (ice-9 ftw)
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 regex)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13)
             (wolk-jjba secrets))

;;; ====== Where things are ======

(define (local-directory)
  "Return the directory holding the encrypted secrets on this machine."
  (or (getenv "WOLK_JJBA_SECRETS_LOCAL")
      (string-append (or (getenv "HOME") ".") "/.config/wolk-jjba/secrets")))

(define (remote-host)
  "Return the ssh alias of the machine the secrets are deployed to."
  (or (getenv "WOLK_JJBA_HOST") "wolk-jjba"))

;; Where the machine keeps the canonical copy.  It is the same directory
;; (wolk-jjba secrets) reads, and the remote half of this program never
;; chooses it: it is spelled out here once.
(define remote-directory "/etc/secrets")

(define secrets-usage
  "Usage: secrets COMMAND [ARGS]

  list                 what is encrypted here, and what the machine has
  set NAME             encrypt a value for NAME, then push it
  edit NAME            edit the value of NAME in $EDITOR, then push it
  get NAME             print the decrypted value of NAME
  push [NAME...]       push the secrets to the machine and apply them
  apply                run the machine's secrets-apply job
  keygen               create the GPG key the secrets are encrypted to

Environment:
  WOLK_JJBA_SECRETS_LOCAL  where the encrypted files live
                           (default ~/.config/wolk-jjba/secrets)
  WOLK_JJBA_HOST           the ssh alias of the machine (default wolk-jjba)
  EDITOR                   the editor `edit' opens (default vi)

`maak secrets' runs this with no arguments, which is the same as
`secrets push': the common case is one keystroke.
")

;;; ====== Talking to the terminal ======

(define (say template . arguments)
  "Print a line, flush it, so a prompt is visible before the input."
  (apply format #t template arguments)
  (force-output))

(define (warn template . arguments)
  "Print a line to stderr, flushed."
  (apply format (current-error-port) template arguments)
  (force-output (current-error-port)))

(define (die template . arguments)
  "Explain what went wrong and exit 1."
  (display "secrets: " (current-error-port))
  (apply warn template arguments)
  (newline (current-error-port))
  (exit 1))

;;; ====== Running programs ======

(define (exit-status program . arguments)
  "Run PROGRAM with ARGUMENTS, inheriting the terminal; return its status.

#f when the program could not be started at all, which is a different
failure from a non-zero exit and deserves a different message."
  (catch 'system-error
    (lambda ()
      (let ((status (apply system* program arguments)))
        (and status (status:exit-val status))))
    (lambda args #f)))

(define (capture program . arguments)
  "Run PROGRAM with ARGUMENTS; return (STATUS . OUTPUT).

The output is read to the end before the pipe is closed, so a program
that writes more than a pipe buffer cannot deadlock the caller."
  (let ((port (catch 'system-error
                (lambda ()
                  (apply open-pipe* OPEN_READ program arguments))
                (lambda args #f))))
    (if (not port)
        (cons #f "")
        (let ((output (get-string-all port)))
          (cons (status:exit-val (close-pipe port)) output)))))

(define (feed input program . arguments)
  "Run PROGRAM with ARGUMENTS and write INPUT to its standard input.

This is how a secret travels: it is already in this process's memory, and
it goes into the child's stdin rather than into its argv, where `ps' would
show it to every user on the machine."
  (let ((port (catch 'system-error
                (lambda ()
                  (apply open-pipe* OPEN_WRITE program arguments))
                (lambda args #f))))
    (if (not port)
        #f
        (begin
          (display input port)
          (force-output port)
          (status:exit-val (close-pipe port))))))

(define (succeeded? status)
  "Return #t when STATUS is a successful exit code."
  (and status (zero? status)))

;;; ====== Files ======

(define (ensure-directory directory)
  "Create DIRECTORY and its parents, each 0700.

Private from the start: the secrets directory holds ciphertext, but the
scratch directory of `edit' holds the plaintext of one."
  (unless (file-exists? directory)
    (ensure-directory (dirname directory))
    (mkdir directory #o700)
    (chmod directory #o700)))

(define (read-file-content path)
  "Return the whole of PATH as a string, or \"\" when it cannot be read."
  (if (file-exists? path)
      (call-with-input-file path get-string-all)
      ""))

(define (write-file-content path content)
  "Write CONTENT to PATH with mode 0600."
  (call-with-output-file path
    (lambda (port)
      (display content port)))
  (chmod path #o600))

(define (remove-if-present path)
  (when (file-exists? path)
    (delete-file path)))

;; A secret name is a file name that cannot surprise anybody: lowercase,
;; digits, and the three punctuation marks names like `grafana-smtp',
;; `github.oauth' and `mpd_admin' need.  No slash, no dot-dot, no shell
;; metacharacter -- the name reaches a remote `install' as one argument and
;; a local file name as another, and neither should have to defend itself.
(define (secret-name? name)
  "Return #t when NAME is a usable secret name."
  (and (string? name)
       (not (string-null? name))
       (string-match "^[a-z0-9][a-z0-9._-]*$" name)
       #t))

(define (check-name name)
  "Return NAME if it is a usable secret name, or exit explaining why not."
  (unless (secret-name? name)
    (die "~a is not a secret name~%Use lowercase letters, digits, dot, dash and underscore: e.g. dockerhub-token.~%"
         (if name name "(none given)")))
  name)

(define (local-secret-path name)
  (string-append (local-directory) "/" name ".gpg"))

(define (secret-files)
  "Return the (NAME . PATH) pairs of the encrypted secrets, sorted."
  (let ((directory (local-directory)))
    (if (not (and (file-exists? directory)
                  (file-is-directory? directory)))
        '()
        (sort (filter-map (lambda (entry)
                            (and (string-suffix? ".gpg" entry)
                                 (let ((name (string-drop-right entry 4)))
                                   (and (secret-name? name)
                                        (cons name (string-append
                                                    directory "/" entry))))))
                          (scandir directory))
              (lambda (a b)
                (string<? (car a) (car b)))))))

;;; ====== GnuPG ======

(define (default-key-fingerprint)
  "Return the fingerprint of the first secret key gpg knows, or #f.

`--with-colons' is gpg's machine-readable listing: one record per line,
fields separated by colons, and the fingerprint of a key is the tenth
field of the `fpr' record that follows its `sec' record."
  (let* ((result (capture "gpg" "--list-secret-keys" "--with-colons"))
         (status (car result))
         (lines (if (succeeded? status)
                    (string-split (cdr result) #\newline)
                    '())))
    (let loop ((remaining lines) (after-secret-key? #f))
      (cond
       ((null? remaining) #f)
       ((string-prefix? "sec:" (car remaining))
        (loop (cdr remaining) #t))
       ((and after-secret-key? (string-prefix? "fpr:" (car remaining)))
        (let ((fields (string-split (car remaining) #\:)))
          (and (> (length fields) 9)
               (not (string-null? (list-ref fields 9)))
               (list-ref fields 9))))
       (else (loop (cdr remaining) #f))))))

(define (recipients-file)
  (string-append (local-directory) "/recipients"))

(define (listed-recipients)
  "Return the key ids in the `recipients' file, comments and blanks aside."
  (let ((path (recipients-file)))
    (if (not (file-exists? path))
        '()
        (filter (lambda (line)
                  (and (not (string-null? line))
                       (not (string-prefix? "#" line))))
                (map string-trim-both
                     (string-split (read-file-content path) #\newline))))))

(define (recipients)
  "Return the key ids the secrets are encrypted to.

The `recipients' file wins when it exists: that is how a second key -- a
backup machine, a colleague -- gets a copy without changing this program.
Without it, the machine's own secret key is enough, and `keygen' makes
one when there is none."
  (let ((listed (listed-recipients)))
    (if (pair? listed)
        listed
        (let ((key (default-key-fingerprint)))
          (if key
              (list key)
              (die "no GPG key to encrypt to~%Run `maak secrets keygen' once (it creates one and prints the fingerprint), or write the key ids into ~a, one per line.~%"
                   (recipients-file)))))))

(define (decrypt path)
  "Return the plaintext of the secret at PATH, or #f when it will not open.

#f rather than \"\" because the caller must not push an empty secret: an
empty token on the machine is a 401 that looks like a wrong token, and
the reason -- the file did not decrypt here -- would be invisible."
  (let ((result (capture "gpg" "--quiet" "--decrypt" path)))
    (and (succeeded? (car result))
         (cdr result))))

(define (encrypt! name value)
  "Encrypt VALUE into the file of NAME and return its path."
  (ensure-directory (local-directory))
  (let* ((path (local-secret-path name))
         (status (apply feed value "gpg"
                        (append (list "--quiet" "--yes" "--encrypt")
                                (append-map (lambda (recipient)
                                              (list "--recipient" recipient))
                                            (recipients))
                                (list "--output" path)))))
    (unless (succeeded? status)
      (remove-if-present path)
      (die "gpg could not encrypt ~a (exit ~a); nothing was written"
           path (if status status "?")))
    (chmod path #o600)
    (say "~a: encrypted to ~a~%"
         path (string-join (recipients) ", "))
    path))

;;; ====== Reading a value ======

(define (read-hidden-line name)
  "Read one line from the terminal without echoing it."
  (say "value for ~a (not echoed): " name)
  (let ((terminal (open-input-file "/dev/tty")))
    (dynamic-wind
      (lambda ()
        ;; `stty' must be told *which* terminal: the process's stdin may
        ;; be a pipe.
        (exit-status "sh" "-c" "stty -echo < /dev/tty"))
      (lambda ()
        (let ((line (read-line terminal)))
          (and (not (eof-object? line)) line)))
      (lambda ()
        (exit-status "sh" "-c" "stty echo < /dev/tty")
        (close-port terminal)
        (newline)))))

(define (read-value name)
  "Read the value of NAME: hidden from a terminal, plain from a pipe.

The piped form is what makes this usable from another script -- and it is
how the test suite drives it -- without a pseudo-terminal.
  printf '%s' \"$TOKEN\" | maak secrets set dockerhub-token"
  (if (isatty? (current-input-port))
      (read-hidden-line name)
      (let ((line (read-line)))
        (and (not (eof-object? line)) line))))

;;; ====== The machine's side ======

(define (push-one name path)
  "Install the secret at PATH on the machine as /etc/secrets/NAME."
  (let ((value (decrypt path)))
    (unless value
      (die "~a does not decrypt; not pushing it~%Check that your GPG key is unlocked, then try again." path))
    (say "→ ~a:~a~%" (remote-host) (secret-path name remote-directory))
    (let ((status (feed value "ssh" (remote-host)
                        "sudo" "install" "-m" "600" "-o" "root" "-g" "root"
                        "/dev/stdin" (secret-path name remote-directory))))
      (unless (succeeded? status)
        (die "could not install /etc/secrets/~a on ~a (exit ~a)~%The usual causes: `ssh ~a' does not work from here, or sudo asks for a password there.~%"
             name (remote-host) (if status status "?") (remote-host))))))

(define (push-files files)
  "Push FILES -- (NAME . PATH) pairs -- apply them, and report.

Every path through this program ends here, so the answer to \"did it
work?\" is always the same screen: what the machine's timer logged, and
who podman there thinks it is."
  (if (null? files)
      (say "nothing to push: no encrypted secrets in ~a~%" (local-directory))
      (begin
        (for-each (lambda (entry)
                    (push-one (car entry) (cdr entry)))
                  files)
        (apply-on-machine)
        (show-report))))

(define (apply-on-machine)
  "Ask the machine to derive its files from /etc/secrets now.

The machine does this on its own every quarter of an hour; this is only
so the answer to \"did it work?\" is a second away instead of a quarter
of an hour."
  (let ((status (exit-status "ssh" (remote-host)
                             "sudo" "herd" "trigger" "secrets-apply")))
    (if (succeeded? status)
        (say "~a: secrets-apply ran~%" (remote-host))
        (say "~a: `herd trigger secrets-apply' failed -- a machine that has not been reconfigured with this service yet needs `maak sr' once. Nothing is lost: the secrets are installed, and the next timer run derives them.~%"
             (remote-host)))))

(define (show-report)
  "Show what the machine did, and who podman there is logged in as."
  (say "~%--- ~a:/var/log/wolk-jjba/secrets-apply.log ---~%" (remote-host))
  (exit-status "ssh" (remote-host) "sudo" "tail" "-n" "12"
               "/var/log/wolk-jjba/secrets-apply.log")
  (unless (null? wolk-jjba-registries)
    (say "~%--- podman on ~a ---~%" (remote-host))
    (for-each (lambda (credential)
                (let* ((registry (registry-credential-registry credential))
                       (result (capture "ssh" (remote-host)
                                        "podman" "login" "--get-login" registry))
                       (who (and (succeeded? (car result))
                                 (string-trim-both (cdr result)))))
                  (if who
                      (say "  ~a: logged in as ~a~%" registry who)
                      (say "  ~a: not logged in (yet)~%"
                           registry))))
              wolk-jjba-registries)))

;;; ====== Commands ======

(define (argument-list arguments)
  (filter (lambda (argument)
            (not (string-prefix? "-" argument)))
          arguments))

(define (command-list arguments)
  (let* ((local (secret-files))
         (result (capture "ssh" (remote-host) "ls" "-1" remote-directory))
         (remote (if (succeeded? (car result))
                     (filter (lambda (line) (not (string-null? line)))
                             (string-split (cdr result) #\newline))
                     '())))
    (say "~a~%" (local-directory))
    (if (null? local)
        (say "  (no encrypted secrets yet)~%")
        (for-each (lambda (entry)
                    (say "  ~a~a~%"
                         (car entry)
                         (if (member (car entry) remote) "  [on the machine]" "")))
                  local))
    (unless (succeeded? (car result))
      (say "~%(could not list ~a on ~a -- is `ssh ~a' working?)~%"
           remote-directory (remote-host) (remote-host)))
    (let ((orphans (if (succeeded? (car result))
                       (sort (lset-difference string=? remote (map car local))
                             string<?)
                       '())))
      (unless (null? orphans)
        (say "~%only on the machine:~%")
        (for-each (lambda (name)
                    (say "  ~a~%" name))
                  orphans)))
    0))

(define (command-set arguments)
  (let* ((name (check-name (and (pair? arguments) (car arguments))))
         (value (read-value name)))
    (when (or (not value) (string-null? value))
      (die "no value given for ~a; nothing was written" name))
    (push-files (list (cons name (encrypt! name (string-append value "\n")))))
    0))

(define (command-edit arguments)
  (let* ((name (check-name (and (pair? arguments) (car arguments))))
         (path (local-secret-path name))
         (scratch-directory (string-append
                             (or (getenv "XDG_RUNTIME_DIR") "/tmp")
                             "/wolk-jjba-secrets"))
         (scratch (string-append scratch-directory "/" name))
         (editor (or (getenv "EDITOR") "vi")))
    (ensure-directory scratch-directory)
    (let ((value
           (dynamic-wind
             (lambda ()
               ;; The scratch directory is 0700 under XDG_RUNTIME_DIR,
               ;; which is a tmpfs: the plaintext of a secret exists there
               ;; for as long as the editor is open, and nowhere else.
               (write-file-content scratch (or (decrypt path) ""))
               (say "editing ~a (~a bytes); it is pushed when the editor exits~%"
                    name (string-length (read-file-content scratch))))
             (lambda ()
               ;; EDITOR may carry arguments of its own ("emacs -nw"), so
               ;; this is the one place a shell is the right tool: the file
               ;; name is quoted for it, and it is a path this program made.
               (unless (succeeded? (exit-status
                                    "sh" "-c"
                                    (format #f "~a '~a'" editor scratch)))
                 (die "the editor exited with an error; ~a is unchanged" path))
               (read-file-content scratch))
             (lambda ()
               (remove-if-present scratch)))))
      (when (string-null? value)
        (die "the edited secret is empty; ~a is unchanged" path))
      (push-files (list (cons name (encrypt! name value))))
      0)))

(define (command-get arguments)
  (let* ((name (check-name (and (pair? arguments) (car arguments))))
         (value (decrypt (local-secret-path name))))
    (unless value
      (die "~a does not decrypt -- is it there, and is your key unlocked?"
           (local-secret-path name)))
    (display value)
    0))

(define (command-push arguments)
  (let* ((named (argument-list arguments))
         (files (if (null? named)
                    (secret-files)
                    (map (lambda (name)
                           (check-name name)
                           (cons name (local-secret-path name)))
                         named))))
    (push-files files)
    0))

(define (command-apply arguments)
  (apply-on-machine)
  (show-report)
  0)

(define (command-keygen arguments)
  (let ((existing (default-key-fingerprint)))
    (if existing
        (begin
          (say "a GPG key already exists: ~a~%" existing)
          (say "the secrets are encrypted to it unless ~a lists others~%"
               (recipients-file))
          0)
        (begin
          (say "no GPG key found; creating one for the wolk-jjba secrets~%")
          (say "gpg will ask for a passphrase: it protects the key that opens every secret~%")
          (let ((status (exit-status "gpg" "--quick-generate-key"
                                     (format #f "wolk-jjba secrets <~a@wolk-jjba>"
                                             (or (getenv "USER") "joe"))
                                     "default" "default" "never")))
            (unless (succeeded? status)
              (die "gpg could not create a key (exit ~a)"
                   (if status status "?")))
            (say "created ~a~%" (default-key-fingerprint))
            0)))))

(define commands
  `(("list" . ,command-list)
    ("ls" . ,command-list)
    ("set" . ,command-set)
    ("edit" . ,command-edit)
    ("get" . ,command-get)
    ("show" . ,command-get)
    ("push" . ,command-push)
    ("apply" . ,command-apply)
    ("keygen" . ,command-keygen)))

(define* (main #:key (argv (command-line)))
  "Run the secrets command line and return its exit status."
  (let ((arguments (cdr argv)))
    (cond
     ((null? arguments)
      ;; `maak secrets' with no argument is the common case: deploy.
      (command-push '()))
     ((member (car arguments) '("--help" "-h" "help"))
      (display secrets-usage)
      0)
     (else
      (let ((command (assoc (car arguments) commands)))
        (cond
         (command ((cdr command) (cdr arguments)))
         (else
          (warn "secrets: unknown command: ~a~%~a" (car arguments) secrets-usage)
          1)))))))

(exit (main))
