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

(define (parent-directory file-name)
  "Return the directory part of FILE-NAME."
  (string-join (reverse (cdr (reverse (string-split file-name #\/)))) "/"))

(define (repository-root)
  "Return the directory holding this file.

`current-filename' is the real path of maak.scm -- maak resolves it with
`realpath' before loading it -- so this is right however the task was
started: absolute path, relative path, or through a symlink."
  (or (and=> (current-filename) parent-directory)
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

(define (require-checkout)
  "Fail with an explanation when this is not a complete checkout.

Called before a reconfigure: an empty or half-cloned directory used to
surface as `guix system: error: loading \"config.scm\" failed', which
says nothing about what to do.  This says what is missing, where it
looked, and how to repair a Byggsteg job clone."
  ($ (list (string-append
            "if [ ! -f config.scm ] || [ ! -d src/wolk-jjba ]; then "
            "echo \"maak: $(pwd) is not a complete wolk-jjba checkout\" >&2; "
            "echo \"maak: it needs config.scm and src/wolk-jjba -- both are in git\" >&2; "
            "echo \"maak: a Byggsteg job clone is re-cloned for every CI job; if this\" >&2; "
            "echo \"maak: happens again, repair it with: git -C $(pwd) reset --hard origin/trunk\" >&2; "
            "exit 1; fi"))))

(define (default)
  "Default task to run, call program's help."
  (list-tasks))

(define (repl)
  "Development REPL."
  (time-machine-manifest-shell '("guile -L ./src"
                                 "-c '((@ (ares server) run-nrepl-server))'")))

(define (gfs-backup . args)
  "Clean the long-term backup archive with the GFS strategy.

Runs as a dry run unless --apply is passed; the server runs the same
program with --apply once a day as the gfs-backup Shepherd timer."
  (time-machine-manifest-shell
   (list (string-append "guile -L ./src ./scripts/gfs-backup.scm "
                        (string-join args " ")))))

(define (test)
  "Run the Veritas unit-test suite, one process per test file.

Runs inside the manifest shell like the other Scheme tasks: the suite
imports (guix gexp) and (gnu services ...) and needs veritas, none of
which are in the machine's system profile, so a bare `guile' fails with
`no code for module (veritas runner)' -- which is what the Byggsteg CI
task `maak-test' used to hit."
  (time-machine-manifest-shell
   '("env VERITAS_JOBS=4 guile -L ./src -L ./test"
     "-c '(use-modules (veritas runner)) (run-tests)'")))

(define has-formatted-already?
  #f)
(define (fmt)
  "Format Scheme source code files according to the Guix style guide."
  (unless has-formatted-already?
    ($ '("find . -maxdepth 8 -name '*.scm'"
         "-type f -exec guix style -f {} \\;")
       #:verbose? #t)
    (set! has-formatted-already? #t)))

(define (full-gc)
  "Performs a full garbage collection across Guix and Nix stores.

The server runs the age-limited version of this on its own every Sunday
(guix-gc in (wolk-jjba maintenance)); this is the by-hand version, which
deletes every old generation first."
  ($ '("guix home delete-generations"))
  ($ '("sudo guix system delete-generations"))
  ($ '("sudo guix gc"))
  ($ '("nix-store --gc")))

(define (guix-pull)
  "Update Guix and the jointhefreeworld channel to the pinned revisions.

The system and the Home environment are built with the guix this leaves in
place, so a reconfigure after a pull picks up the newer maak, veritas and
Guile libraries the channel carries."
  ($ '("guix pull" "--channels=channels.scm")
     #:verbose? #t)
  ($ '("hash guix")
     #:verbose? #t))

(define (system-reconfigure)
  "Pull updates, provision web directories, and reconfigure the Guix System.

Run `maak guix-pull' first when the channel itself should move; this task
reconfigures with the guix the machine already has."
  (require-checkout)
  ($ '("sudo git fetch --all || true"))
  ($ '("sudo git pull || true"))
  ($ '("sudo mkdir -p /srv/http/jointhefreeworld.org"))
  ($ '("sudo mkdir -p /srv/http/carvoeirowaterfun.com"))
  ($ '("sudo mkdir -p /srv/http"))
  ($ '("echo \"Hello World! (from wolk-jjba)\" | sudo tee /srv/http/index.html"))
  ($ '("sudo guix system reconfigure -L ./src config.scm --fallback")))

(define (joe-reconfigure)
  "Pull updates and reconfigure the Guix Home environment for user 'joe'."
  (require-checkout)
  ($ '("sudo git fetch --all || true"))
  ($ '("sudo git pull || true"))
  ($ '("guix home reconfigure -L ./src home/joe.scm --fallback")))

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
