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
;; The secrets contract: where a secret comes from, where it lives on the
;; machine, and what the machine derives from it.
;;
;; Three rules, and everything below follows from them.
;;
;; 1. A secret is authored once, on a machine a human is sitting at, and
;;    kept there encrypted -- one GPG file per secret, in
;;    ~/.config/wolk-jjba/secrets/, which is never committed (`maak
;;    secrets-set', `maak secrets-edit' and `maak secrets' in maak.scm are
;;    that half of the story).  The repository is public and a token in it
;;    would be a token for everyone.
;;
;; 2. On this machine a secret is a root-only file in /etc/secrets/<name>,
;;    one line, mode 0600, and that file is the canonical copy.  Nothing
;;    reads a secret from anywhere else: the radio passwords are read from
;;    it while config.scm is evaluated, and everything else is derived
;;    from it here.
;;
;; 3. A derived file is written by the machine and never by hand.  Podman
;;    has no "token" flag -- it reads `auth.json' from the account's home
;;    -- so logging in to a registry means writing one file per account
;;    that builds containers.  `secrets-apply' does that from /etc/secrets
;;    on a timer (see (wolk-jjba containers)), which is what makes the
;;    login survive a reinstall of a home, a reboot or a reconfigure with
;;    nobody running `podman login' on the machine -- a command that also
;;    leaves the token in a shell history.
;;
;; A secret that is not there is not an error.  A machine that pulls no
;; private image is a working machine: the timer logs "nothing to derive"
;; every quarter of an hour and exits 0, because a red unit on a box that
;; is doing exactly what it should is worse than no unit at all.
;;
;; Why this module is plain Guile
;; ------------------------------
;; (wolk-jjba containers) turns `apply-secrets' into a `program-file' with
;; `source-module-closure ... #:select? wolk-jjba-module?', the same way
;; (wolk-jjba maintenance) runs (wolk-jjba gfs): only this repository's
;; modules travel into the store with the program, and Guile's own
;; library is the interpreter's.  So an import of `(guix gexp)' or
;; `(gnu services)' here would not be on the program's load path, and the
;; program would die with "no code for module (guix gexp)" the first time
;; the timer fired -- at 4 in the morning, in a log nobody reads.  Guile
;; 3.0 also has no base64 module, hence the encoder below.
;;
;; Code:

(define-module (wolk-jjba secrets)
  #:use-module (ice-9 format)
  ;; read-line and get-string-all are not in (guile): (ice-9 rdelim) and
  ;; (ice-9 textual-ports) have them, both standard library, so the
  ;; Shepherd program below can still import this module on its own.
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  ;; string->utf8 lives in (rnrs bytevectors), which is where Guile keeps
  ;; it; the base64 encoder below works on bytes, not characters, so that
  ;; a token with a UTF-8 character in it is encoded the way the registry
  ;; computes it.
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:export (wolk-jjba-secrets-directory
            secret-path
            secret-present?
            read-secret
            secret-token
            registry-credential
            registry-credential?
            registry-credential-registry
            registry-credential-username
            registry-credential-secret
            wolk-jjba-registries
            base64-encode-string
            registry-auth-json
            apply-secrets
            main))

;;; ====== The canonical copy ======

;; Every capability that reads a secret agrees on this directory, and so
;; does the tool that puts a secret there (`maak secrets'), so there is no
;; second list of names to keep in step.
;;
;; The variable exists for the two situations where /etc/secrets is the
;; wrong answer: a build running as an ordinary user -- `guix system
;; build' cannot open a root-only file, and neither can the test suite --
;; and the fixtures in test/veritas/unit/operating-system-spec.scm, which
;; evaluate config.scm against files they write themselves.
(define wolk-jjba-secrets-directory
  (or (getenv "WOLK_JJBA_SECRETS") "/etc/secrets"))

(define* (secret-path name #:optional (directory wolk-jjba-secrets-directory))
  "Return the path of the secret NAME in DIRECTORY."
  (format #f "~a/~a" directory name))

(define* (secret-present? name #:optional (directory wolk-jjba-secrets-directory))
  "Return #t when the secret NAME exists in DIRECTORY."
  (file-exists? (secret-path name directory)))

(define (read-secret name)
  "Return the first line of the secret file NAME.

Signals an error that names the missing file and lists the four secrets
the radio needs."
  (let ((path (secret-path name)))
    (if (file-exists? path)
        (call-with-input-file path read-line)
        (error
         (string-append
          "missing secret: " path "\n"
          "The radio reads four secrets from " wolk-jjba-secrets-directory
          ": mpd-admin, mpd-read, icecast-source and icecast-admin.\n"
          "Create them as described in \"Create the secrets\" in README.org, e.g.\n"
          "  openssl rand -base64 24 | sudo tee " path " >/dev/null\n"
          "  sudo chmod 600 " path "\n"
          "or push them from the machine you keep them on with `maak secrets'.")))))

(define* (secret-token name #:key (directory wolk-jjba-secrets-directory))
  "Return the first line of the secret NAME, trimmed, or #f if it is absent.

Only the first line, and trimmed, because these files are written by hand
at least once: `printf' without a newline, an editor that adds one, a
paste with a trailing space.  A token with a trailing newline is a token
the registry answers 401 to, and the error it produces -- unauthorized,
incorrect username or password -- points at the token rather than at the
whitespace.

A secret that is absent, empty or made only of whitespace is #f: it has
no value to derive anything from, and the caller decides whether that is
worth saying out loud."
  (let ((path (secret-path name directory)))
    (and (file-exists? path)
         (call-with-input-file path
           (lambda (port)
             (let ((line (read-line port)))
               ;; An empty file reads as the eof object, which is true in
               ;; Scheme: without the check, `string-trim-both' would be
               ;; handed #<eof> and the whole of `secrets-apply' would
               ;; stop on a secret that is merely empty.
               (and (not (eof-object? line))
                    (let ((trimmed (string-trim-both line)))
                      (and (not (string-null? trimmed)) trimmed)))))))))

;;; ====== Registry credentials ======

(define-record-type <registry-credential>
  (make-registry-credential registry username secret)
  registry-credential?
  (registry registry-credential-registry)
  (username registry-credential-username)
  (secret registry-credential-secret))

(define* (registry-credential #:key registry username secret)
  "Return a registry credential: who logs in, to what, with which secret.

REGISTRY is the registry host as podman spells it (`docker.io', not
`index.docker.io' and not a URL, which is what podman writes into
auth.json itself), USERNAME the account the token belongs to -- not a
secret, so it lives here -- and SECRET the name of the file in
/etc/secrets that holds the token."
  (unless (and registry username secret)
    (error "registry-credential needs #:registry, #:username and #:secret"))
  (make-registry-credential registry username secret))

;; The registries this machine pulls private images from.  Docker Hub's
;; rate-limited anonymous pulls are why this exists at all: an access
;; token raises the limit and reaches the private repositories of the
;; account, and it is revocable from hub.docker.com without touching
;; anything here.
;;
;; The token is a *personal access token*, not the account password
;; (Docker Hub -> Account settings -> Security -> New access token).  It
;; has no scopes to choose: read access is enough for a build host, and
;; that is what a plain token grants.
;;
;; A second registry is one more entry -- ghcr.io and quay.io are the
;; likely ones -- plus its token in /etc/secrets.  Nothing else changes:
;; `secrets-apply' writes one auth.json per account holding every
;; registry, which is exactly the file `podman login' would have grown.
(define wolk-jjba-registries
  (list (registry-credential #:registry "docker.io"
                             #:username "jjba23"
                             #:secret "dockerhub-token")))

;;; ====== auth.json ======

;; Guile 3.0 ships no base64 (there is no (ice-9 base64) module to
;; import), and the value `auth.json' wants is base64 of
;; "username:token".  Sixteen lines of RFC 4648 beat a call to
;; /run/current-system/profile/bin/base64: the encoder can be run by the
;; test suite on any machine, it cannot fail because a PATH entry was
;; wrong, and a token never has to be handed to a subprocess.
(define base64-alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (base64-digit value)
  "Return the base64 character for VALUE, a number below 64."
  (string-ref base64-alphabet value))

(define (base64-encode-string text)
  "Return TEXT, encoded as UTF-8, in base64 with padding.

RFC 4648's standard alphabet: three bytes become four characters, and a
final group of one or two bytes is padded with `='."
  (let* ((bytes (string->utf8 text))
         (length (bytevector-length bytes)))
    (let loop ((index 0) (chunks '()))
      (if (>= index length)
          (apply string-append (reverse chunks))
          (let* ((b0 (bytevector-u8-ref bytes index))
                 (has-second? (< (+ index 1) length))
                 (has-third? (< (+ index 2) length))
                 (b1 (if has-second? (bytevector-u8-ref bytes (+ index 1)) 0))
                 (b2 (if has-third? (bytevector-u8-ref bytes (+ index 2)) 0))
                 (group (+ (* b0 65536) (* b1 256) b2)))
            (loop (+ index 3)
                  (cons (string (base64-digit (quotient group 262144))
                                (base64-digit
                                 (quotient (modulo group 262144) 4096))
                                (if has-second?
                                    (base64-digit
                                     (quotient (modulo group 4096) 64))
                                    #\=)
                                (if has-third?
                                    (base64-digit (modulo group 64))
                                    #\=))
                        chunks)))))))

(define json-special-character?
  (lambda (character)
    (memv character (list #\" #\\ #\newline #\return #\tab))))

(define (registry-auth-json registry username token)
  "Return the auth.json body that logs USERNAME in to REGISTRY with TOKEN.

The file podman and docker read before a pull:

  {\"auths\": {\"docker.io\": {\"auth\": \"<base64 of user:token>\"}}}

Note what that `auth' value is: plain base64, not a hash and not an
encrypted blob.  Base64 is transport encoding, so auth.json *is* the
password in a light disguise -- which is why it is written 0600, owned by
the account that pulls, and derived from /etc/secrets rather than kept
anywhere a `git add' could reach it."
  (for-each (lambda (value what)
              (when (string-any json-special-character? value)
                (error
                 (format #f
                         "refusing to write a registry credential: ~a contains ~s, which JSON would need escaped"
                         what value))))
            (list registry username)
            '("the registry" "the username"))
  (format #f "{\"auths\": {\"~a\": {\"auth\": \"~a\"}}}~%"
          registry
          (base64-encode-string (string-append username ":" token))))

;;; ====== The files derived from the secrets ======

(define (default-user-info user)
  "Return (uid gid home) for USER, or #f when there is no such account.

The passwd entry is read from the machine, never assumed: uid 1000 is
joe's on this machine and is not a rule, and a home directory is wherever
the account was created."
  (let ((entry (getpwnam user)))
    (and entry
         (list (passwd:uid entry) (passwd:gid entry) (passwd:dir entry)))))

(define (make-owner-directory directory uid gid)
  "Create DIRECTORY, and any missing parent, owned by UID/GID.

Only what had to be created is chowned and chmoded: a `~/.config' that
already exists was made by the account it belongs to, and its mode is not
this program's to decide.  A directory created here is 0700 -- podman
then creates auth.json in a directory only its owner can open."
  (unless (file-exists? directory)
    (make-owner-directory (dirname directory) uid gid)
    (mkdir directory #o700)
    (chown directory uid gid)
    (chmod directory #o700)))

(define* (install-derived-file file content uid gid #:key (mode #o600))
  "Write CONTENT to FILE as MODE, owned by UID/GID; return the status.

The status is `written' or `unchanged', and an unchanged file is not
touched at all: the timer runs every quarter of an hour, and rewriting
two files that already say the right thing 96 times a day is churn --
mtime moves, a composable filesystem copies again, and `podman' has no
reason to trust the file any less than before.

A write goes to a temporary name in the same directory and is renamed
into place, with the mode and the owner set *before* the rename.  So
there is no moment at which a pull could read half a file, and none at
which the file is readable by anyone but its owner."
  (if (and (file-exists? file)
           (string=? (call-with-input-file file get-string-all) content))
      'unchanged
      (let ((temporary (string-append file ".new")))
        (call-with-output-file temporary
          (lambda (port)
            (display content port)))
        (chmod temporary mode)
        (chown temporary uid gid)
        (rename-file temporary file)
        'written)))

(define* (registry-auth-files credential #:key
                              directory
                              (users (list "joe"))
                              (user-info default-user-info)
                              (dry-run? #f)
                              (port (current-output-port)))
  "Write AUTH.JSON for CREDENTIAL into every account in USERS.

Return the (PATH . STATUS) list of what happened to each account, or #f
when the credential's secret is absent -- there is nothing to derive, and
that is not an error.  See `apply-secrets' for the statuses.

Each account has its own copy because that is how podman finds it:
`$HOME/.config/containers/auth.json', resolved through HOME.  There is no
system-wide file that would let one write serve two accounts, and there
should not be: the file is a password."
  (let ((token (secret-token (registry-credential-secret credential)
                             #:directory directory)))
    (and token
         (let* ((registry (registry-credential-registry credential))
                (content (registry-auth-json
                          registry
                          (registry-credential-username credential)
                          token)))
           (map (lambda (user)
                  (let ((info (user-info user)))
                    (if (not info)
                        (begin
                          (format port "~a: no account ~a, skipped~%"
                                  registry user)
                          (cons user 'no-such-user))
                        (let* ((uid (first info))
                               (gid (second info))
                               (home (third info))
                               (file (string-append
                                      home "/.config/containers/auth.json")))
                          (if dry-run?
                              (begin
                                (format port "~a: would write ~a~%"
                                        registry file)
                                (cons file 'would-write))
                              (begin
                                (make-owner-directory (dirname file) uid gid)
                                (let ((status (install-derived-file
                                               file content uid gid)))
                                  (format port "~a: ~a ~a~%"
                                          registry status file)
                                  (cons file status))))))))
                users)))))

(define* (apply-secrets #:key
                        (directory wolk-jjba-secrets-directory)
                        (registries wolk-jjba-registries)
                        (users (list "joe"))
                        (user-info default-user-info)
                        (dry-run? #f)
                        (port (current-output-port)))
  "Write every file that is derived from the secrets in DIRECTORY.

USERS are the accounts that get a copy -- for a registry credential, the
accounts that pull images, each one in its own
~/.config/containers/auth.json.

Returns one report per registry, an alist with `registry', `secret',
`status' ('applied or 'missing) and `files', itself a list of
(PATH . STATUS) with STATUS one of `written', `unchanged',
`would-write' (dry run) or `no-such-user'.

Nothing here is fatal.  A secret that is not there leaves that registry
alone, an account that does not exist is reported and skipped, and the
rest is still written: one bad entry in a list must not cost a machine
its logins."
  (map (lambda (credential)
         (let* ((registry (registry-credential-registry credential))
                (name (registry-credential-secret credential))
                (files (registry-auth-files credential
                                           #:directory directory
                                           #:users users
                                           #:user-info user-info
                                           #:dry-run? dry-run?
                                           #:port port)))
           (if files
               (list (cons 'registry registry)
                     (cons 'secret name)
                     (cons 'status 'applied)
                     (cons 'files files))
               (begin
                 (format port "~a: no ~a, nothing to derive~%"
                         registry (secret-path name directory))
                 (list (cons 'registry registry)
                       (cons 'secret name)
                       (cons 'status 'missing)
                       (cons 'files '()))))))
       registries))

;;; ====== The command line ======

(define secrets-apply-usage
  "Usage: secrets-apply [--apply] [--dry-run] [--directory DIR] [--user NAME]...

Write the files derived from the secrets in /etc/secrets: one
~/.config/containers/auth.json per account named with --user (joe by
default), holding the registry credentials of (wolk-jjba secrets).

  --apply, -a          write the files (the default is a dry run)
  --dry-run, -n        only say what would be written
  --directory, -d DIR  read the secrets from DIR (default /etc/secrets,
                       or $WOLK_JJBA_SECRETS)
  --user, -u NAME      an account that gets a copy; repeatable
  --help, -h           this text

It exits 0 even when a secret is absent: a machine that pulls no private
image is a working machine.  `maak secrets' on the machine that holds the
encrypted copies runs this for you after pushing them.
")

(define* (main #:key (argv (command-line)) (port (current-output-port)))
  "Run the secrets-apply command line and return its exit status."
  (let loop ((arguments (cdr argv))
             (directory wolk-jjba-secrets-directory)
             (users '())
             (apply? #f))
    (cond
      ((null? arguments)
       (let ((users (if (null? users) (list "joe") users)))
         (unless apply?
           (format port "secrets-apply: dry run, nothing will be written~%"))
         (apply-secrets #:directory directory
                        #:users users
                        #:dry-run? (not apply?)
                        #:port port)
         0))
      ((member (car arguments) '("--apply" "-a"))
       (loop (cdr arguments) directory users #t))
      ((member (car arguments) '("--dry-run" "-n"))
       (loop (cdr arguments) directory users #f))
      ((member (car arguments) '("--directory" "-d"))
       (if (null? (cdr arguments))
           (begin
             (format (current-error-port)
                     "secrets-apply: --directory needs a directory~%")
             1)
           (loop (cddr arguments) (cadr arguments) users apply?)))
      ((member (car arguments) '("--user" "-u"))
       (if (null? (cdr arguments))
           (begin
             (format (current-error-port)
                     "secrets-apply: --user needs an account name~%")
             1)
           (loop (cddr arguments) directory
                 (append users (list (cadr arguments)))
                 apply?)))
      ((member (car arguments) '("--help" "-h"))
       (display secrets-apply-usage port)
       0)
      (else
       (format (current-error-port)
               "secrets-apply: unknown argument: ~a~%~a"
               (car arguments)
               secrets-apply-usage)
       1))))
