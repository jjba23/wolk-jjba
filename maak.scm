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
;; Repository tasks, run with maak.
;;
;; maak executes every task with the working directory it was started
;; from, and never changes it.  A task that says `./src' or `config.scm'
;; therefore works only when maak happens to be started in the repository
;; root; started anywhere else it fails with something unrelated to the
;; real cause -- `guix system reconfigure' reports
;; `loading "config.scm" failed: No such file or directory', which reads
;; like a broken configuration rather than a wrong directory.
;;
;; So this file changes the process's working directory to the directory
;; it lives in, once, at load time.  Every task then runs from the
;; checkout, children inherit it (including `guix shell', which execs its
;; command directly rather than through a shell, so a `cd ... &&' prefix
;; would not work there), and the relative paths below mean what they say.
;;
;; `require-checkout' covers the other half of that failure: a directory
;; that is being cloned or updated underneath the task -- which is what a
;; Byggsteg job does to /etc/byggsteg/job-clone/<project>/trunk -- would
;; otherwise look exactly like a broken configuration.

(define-module (maak)
  #:declarative? #t
  #:use-module (maak maak))

(define (repository-root)
  "Return the directory holding this file.

`current-filename' is the real path of maak.scm -- maak resolves it with
`realpath' before loading it -- so this is right however the task was
started: absolute path, relative path, or through a symlink."
  (or (and=> (current-filename) dirname)
      (getcwd)))

;; From here on, every command a task runs starts in the checkout.
(unless (string=? (getcwd) (repository-root))
  (chdir (repository-root)))

;; ... and with the guix the task is running, not the one the login shell
;; remembers.  An exported GUILE_LOAD_PATH (usually pointing at a guix
;; profile from an older `guix pull') makes every `guix' command in a task
;; import (gnu packages ...) from that older tree, and the failure names a
;; variable inside a package definition and a line in manifest.scm --
;; `git-fetch: variable not bound', `license:lgpl3+: variable not bound' --
;; which reads like a broken manifest rather than a stale environment.
;; Guix sets up its own load path; these two variables must not override it.
(unsetenv "GUILE_LOAD_PATH")
(unsetenv "GUILE_LOAD_COMPILED_PATH")

;; ... and with a certificate store the Git support can find.  Guix links its
;; Git support against OpenSSL, whose compiled-in trust store is its own store
;; directory and therefore empty; libgit2 then falls back to
;; /etc/ssl/certs/ca-certificates.crt, which openSUSE does not have -- it keeps
;; the bundle in /etc/ssl/ca-bundle.pem.  Every channel fetch then fails with
;; "Git-fout: the SSL certificate is invalid" before a single object moves,
;; which reads like a network or a channel problem rather than a missing CA
;; file, and it is what `guix time-machine --channels=channels.scm' reported.
;; Point the environment at whichever bundle this machine has: SSL_CERT_FILE is
;; what OpenSSL and libgit2 read, GIT_SSL_CAINFO what a plain `git' reads.  An
;; SSL_CERT_FILE already set wins, so a machine with its own bundle keeps it.
(define ca-bundle-candidates
  '("/etc/ssl/certs/ca-certificates.crt"
    "/etc/ssl/ca-bundle.pem"
    "/etc/pki/tls/certs/ca-bundle.crt"
    "/etc/ssl/cert.pem"))

(define (first-existing-file files)
  "Return the first of FILES that exists, or #f."
  (cond ((null? files) #f)
        ((file-exists? (car files)) (car files))
        (else (first-existing-file (cdr files)))))

(let ((bundle (or (getenv "SSL_CERT_FILE")
                  (first-existing-file ca-bundle-candidates))))
  (when bundle
    (setenv "SSL_CERT_FILE" bundle)
    (setenv "GIT_SSL_CAINFO" bundle)))

(define (require-checkout)
  "Fail with an explanation when this is not a complete checkout.

Called before a reconfigure: an empty or half-cloned directory used to
surface as `guix system: error: loading \"config.scm\" failed', which
says nothing about what to do.  This says what is missing, where it
looked, and how to repair a Byggsteg job clone."
  (let ((root (getcwd)))
    (unless (and (file-exists? "config.scm")
                 (file-exists? "src/wolk-jjba")
                 (file-is-directory? "src/wolk-jjba"))
      (task-error "~a is not a complete wolk-jjba checkout"
                  #:args (list root)
                  #:hint
                  (~ "It needs config.scm and src/wolk-jjba -- both are in git.  A Byggsteg job clone is re-cloned for every CI job; if this happens again, repair it with: git -C ~a reset --hard origin/trunk"
                     root)))))

(define (default)
  "Default task to run, call program's help."
  (list-tasks))

(define (repl)
  "Development REPL."
  (time-machine-manifest-shell
   (list "guile" "-L" "./src"
         "-c" "'((@ (ares server) run-nrepl-server))'")))

(define (gfs-backup . args)
  "Clean the long-term backup archive with the GFS strategy.

Runs as a dry run unless --apply is passed; the server runs the same
program with --apply once a day as the gfs-backup Shepherd timer."
  (time-machine-manifest-shell
   (append (list "guile" "-L" "./src" "./scripts/gfs-backup.scm")
           args)))

(define (test)
  "Run the Veritas unit-test suite, one process per test file.

Runs inside the manifest shell like the other Scheme tasks: the suite
imports (guix gexp) and (gnu services ...) and needs veritas, none of
which are in the machine's system profile, so a bare `guile' fails with
`no code for module (veritas runner)' -- which is what the Byggsteg CI
task `maak-test' used to hit."
  (time-machine-manifest-shell
   (list "guile" "-L" "./src" "-L" "./test"
         "-c" "'(use-modules (veritas runner)) (run-tests)'")
   #:env '("VERITAS_JOBS=4")))

(define has-formatted-already?
  #f)
(define (fmt)
  "Format Scheme source code files according to the Guix style guide."
  (unless has-formatted-already?
    (run (list "find" "." "-maxdepth" "8" "-name" "*.scm"
               "-type" "f" "-exec" "guix" "style" "-f" "{}" ";")
         #:verbose? #t)
    (set! has-formatted-already? #t)))

(define (full-gc)
  "Performs a full garbage collection across Guix and Nix stores.

The server runs the age-limited version of this on its own every Sunday
(guix-gc in (wolk-jjba maintenance)); this is the by-hand version, which
deletes every old generation first."
  (run (list "guix" "home" "delete-generations"))
  (run (list "guix" "system" "delete-generations") #:sudo? #t)
  (run (list "guix" "gc") #:sudo? #t)
  (run (list "nix-store" "--gc")))

;; The guix the tasks build with.
;;
;; `sudo guix' runs root's guix, which has root's own channel list and no
;; jointhefreeworld channel there, so config.scm would fail while it imports
;; (wolk-jjba packages) with "wolk-jjba-system-packages: variabele niet
;; gebonden" -- the module is registered but the failed channel import left it
;; empty.  The user's pulled guix carries the channels from channels.scm, so
;; name that binary explicitly, also under sudo.  SUDO_USER covers the weekly
;; job, which runs `sudo maak fr'.
(define (pulled-guix)
  "Return the guix binary the invoking user pulled, or \"guix\"."
  (let* ((sudo-user (getenv "SUDO_USER"))
         (home (if sudo-user
                   (~ "/home/~a" sudo-user)
                   (or (getenv "HOME") "")))
         (candidate (~ "~a/.config/guix/current/bin/guix" home)))
    (if (file-exists? candidate) candidate "guix")))

(define (guix-pull)
  "Update Guix and the jointhefreeworld channel to the pinned revisions.

The system and the Home environment are built with the guix this leaves in
place, so a reconfigure after a pull picks up the newer maak, veritas and
Guile libraries the channel carries.

channels.scm is copied to ~/.config/guix/trusted-channels.scm first.  Guix
only pulls a channel that carries an introduction if the channel is among the
trusted ones -- the channels in that file, or else the channels the running
guix already has -- and without it the first pull after a channel is added
warns that the channel is not trusted."
  (run (list "install" "-D" "-m" "644" "channels.scm"
             (~ "~a/.config/guix/trusted-channels.scm" (home-dir)))
       #:verbose? #t)
  (run (list (pulled-guix) "pull" "--channels=channels.scm")
       #:verbose? #t)
  ;; `hash' is a shell builtin rather than a program on PATH, so there is
  ;; nothing for `run' to exec.
  ($ '("hash guix")
     #:verbose? #t))

(define (system-reconfigure)
  "Pull updates, provision web directories, and reconfigure the Guix System.

The reconfigure runs as root but with the guix the user pulled, because the
channels in channels.scm -- jointhefreeworld included -- are installed there
and not in root's own guix.  Run `maak guix-pull' first when the channels
should move; this task reconfigures with the guix the machine already has."
  (require-checkout)
  ;; The git wrappers have no `#:sudo?' of their own, and these two run in a
  ;; checkout that belongs to root, so they are spelled with `run'.
  (run (list "git" "fetch" "--all") #:sudo? #t #:allow-failure? #t)
  (run (list "git" "pull") #:sudo? #t #:allow-failure? #t)
  (run (list "mkdir" "-p" "/srv/http/jointhefreeworld.org") #:sudo? #t)
  (run (list "mkdir" "-p" "/srv/http/carvoeirowaterfun.com") #:sudo? #t)
  (run (list "mkdir" "-p" "/srv/http") #:sudo? #t)
  ;; A pipe into a privileged `tee' has no argv spelling.
  ($ '("echo \"Hello World! (from wolk-jjba)\" | sudo tee /srv/http/index.html"))
  (run (list (pulled-guix) "system" "reconfigure" "-L" "./src"
             "config.scm" "--fallback")
       #:sudo? #t))

(define (joe-reconfigure)
  "Pull updates and reconfigure the Guix Home environment for user 'joe'."
  (require-checkout)
  (run (list "git" "fetch" "--all") #:sudo? #t #:allow-failure? #t)
  (run (list "git" "pull") #:sudo? #t #:allow-failure? #t)
  (run (list (pulled-guix) "home" "reconfigure" "-L" "./src"
             "home/joe.scm" "--fallback")))

(define (full-rebuild)
  "Orchestrate a sequential rebuild of both Guix System and Guix Home profiles."
  (system-reconfigure)
  (joe-reconfigure))

(define (sr)
  "Alias for system-reconfigure."
  (system-reconfigure))

(define (jr)
  "Alias for joe-reconfigure."
  (joe-reconfigure))

(define (fr)
  "Alias for full-rebuild."
  (full-rebuild))
