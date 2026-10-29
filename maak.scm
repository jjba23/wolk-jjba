;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

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
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
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

;; ====== Secrets ======
;;
;; The whole contract lives in (wolk-jjba secrets) -- what a secret is on
;; the machine, and what is derived from it -- and in scripts/secrets.scm,
;; which is the half that runs wherever a human is sitting.  This task is
;; the two lines that connect them, plus the docstring that says how.
;;
;; Deploying a secret is therefore one command, and it is one command
;; because the alternative -- ssh in, `sudo install -m 600 /dev/stdin',
;; paste the token, hope the editor did not write a trailing newline --
;; is done wrong eventually.  The three things this does instead:
;;
;;   * the plaintext never lands on either disk: gpg decrypts into a pipe
;;     that ssh carries into `install /dev/stdin', and the machine writes
;;     it root-only;
;;   * the token is never an argument: it does not reach a shell history,
;;     an argv or `ps';
;;   * the machine derives the files that consume it by itself (the
;;     secrets-apply timer in (wolk-jjba containers)), so `podman pull'
;;     of a private image works without `podman login' ever being typed
;;     on the machine, and survives a reinstalled home.
;;
;; It runs wherever it is started: from this machine over ssh, with the
;; host named by WOLK_JJBA_HOST (default `wolk-jjba', which is the alias
;; in ~/.ssh/config).
(define (secrets . args)
  "Deploy a secret to wolk-jjba, or manage the encrypted copy of one.

The encrypted copies live in ~/.config/wolk-jjba/secrets, one GPG file
per secret, and are never committed.  A secret is pushed over ssh into
/etc/secrets on the machine, root-only, and the machine derives from
there whatever consumes it.

  maak secrets                 push every secret, then apply them
  maak secrets list            what is encrypted here, and what the machine has
  maak secrets set NAME        encrypt a value for NAME (hidden prompt), then push it
  maak secrets edit NAME       edit the value in $EDITOR, then push it
  maak secrets get NAME        print the decrypted value here
  maak secrets push [NAME...]  push every secret, or the ones named
  maak secrets apply           only apply them on the machine
  maak secrets keygen          create the GPG key the secrets are encrypted to

The first use case is the Docker Hub token:

  printf '%s' \"$TOKEN\" | maak secrets set dockerhub-token

which leaves /etc/secrets/dockerhub-token on the machine and, through the
secrets-apply timer, ~/.config/containers/auth.json for both accounts that
build containers -- so pulling a private image needs no `podman login'.
The host is WOLK_JJBA_HOST (default wolk-jjba, the alias in ~/.ssh/config);
the whole flow is documented under \"Secrets\" in README.org."
  (require-command "guile"
                   #:hint
                   "This task runs scripts/secrets.scm, which is plain Guile: it needs `guile' on PATH (the manifest shell has one).")
  (require-command "gpg"
                   #:hint
                   "The secrets are GPG files: install gnupg and run `maak secrets keygen' once if you have no key yet.")
  (run (append (list "guile" "-L" "./src" "./scripts/secrets.scm")
               args)))

;; ====== How many processes the suite runs in ======
;;
;; One process per spec file is what makes the suite quick -- the
;; operating-system spec, which evaluates config.scm in a child Guile, is
;; several times the cost of everything else -- but the count is not the
;; same on every machine.  Four workers on a laptop with a dozen cores are
;; free; four workers on a one-core CI runner share that core, and the
;; memory of four Guile processes one of which imports all of Guix, and
;; turn a suite that passes locally into a job that fails once in a while
;; with no failing assertion to point at.
;;
;; So the count is this machine's, capped at four, and VERITAS_JOBS in the
;; environment wins over it.  "This machine's" means what the process may
;; really use, not what the box has: inside a container the kernel reports
;; every core of the *host* while the cgroup gives the job one, and a
;; runner that limits CPU is exactly the one that must not be given four
;; Guile processes -- so a CPU quota wins over /proc, and a runner that
;; limits CPU and memory both can still say VERITAS_JOBS=1.
(define (test-jobs)
  "Return how many worker processes the suite should run in, as a string.

VERITAS_JOBS wins when it is set -- that is how a CI job reruns a failure
serially (`VERITAS_JOBS=1 maak test'), and how a developer reproduces it.
Otherwise: the cgroup CPU quota when there is one, else the processor
count, capped at four."
  (let* ((max-jobs 4)
         (quota-file "/sys/fs/cgroup/cpu.max")
         (quota-text (and (file-exists? quota-file)
                          (read-file quota-file)))
         (quota-fields (and (string? quota-text)
                            (string-split (string-trim-both quota-text)
                                          #\space)))
         ;; cgroup v2 writes "<quota> <period>", or "max <period>" when
         ;; nothing is limited.  A quota of 150000 per 100000 is one and a
         ;; half CPUs, which rounds up to two: the point is to stop
         ;; oversubscribing a throttled container, not to be exact.  Any
         ;; shape this does not recognize -- "max", an empty file, a host
         ;; with no such file -- falls back to the processor count instead
         ;; of failing the task.
         (quota (and quota-fields
                     (string->number (car quota-fields))))
         (period (and quota-fields
                      (> (length quota-fields) 1)
                      (string->number (list-ref quota-fields 1))))
         (cpus (if (and quota period (> quota 0) (> period 0))
                   (ceiling (/ quota period))
                   (or (current-processor-count) 1))))
    (or (getenv "VERITAS_JOBS")
        (format #f "~a" (max 1 (min max-jobs cpus))))))

;; ====== Where the channel's modules are ======
;;
;; The suite needs one directory that the pinned shell does not carry: the
;; jointhefreeworld channel, because config.scm imports (wolk-jjba packages)
;; which imports (jointhefreeworld packages applications).  `guix pull`
;; installs the channel's modules into the guix profile in $HOME, and that
;; is where the suite finds them on a machine someone uses.
;;
;; "In $HOME" is not good enough for CI.  A Byggsteg job runs as root, and
;; root's $HOME has no pulled guix at all -- the machine's guix is the one
;; in the system profile -- so this task exported nothing, the child that
;; evaluates config.scm could not import the channel, and the job failed
;; with `no code for module (jointhefreeworld packages applications)' while
;; the same suite passed on the machine it was written on.
;;
;; Nothing outside guix knows where that module comes from on such a
;; machine, so the task asks it: `guix time-machine --channels=channels.scm
;; -- repl' runs with exactly the channels `maak sr' and `maak test' pin,
;; and its load path is the answer.  The expression prints that path with a
;; marker of its own because `guix repl' prints a banner as well.
(define (guix-channel-module-directory)
  "Return the directory the pinned channels' modules live in, or #f.

#f when guix cannot say, which leaves the suite exactly where it was before:
with whatever channel it finds in $HOME, or with an honest `no code for
module'."
  (let* ((expression
          "(format #t \"WOLK-JJBA-LOAD-PATH ~s~%\" %load-path)")
         (command (string-append
                   "printf '%s' " (shell-quote expression)
                   " | " (pulled-guix)
                   " time-machine --channels=channels.scm -- repl"))
         (output (capture command
                          #:allow-failure? #t
                          #:error? #t))
         (marker "WOLK-JJBA-LOAD-PATH ")
         (line (find (lambda (line)
                       (string-prefix? marker line))
                     (string-split output #\newline))))
    (and line
         (let ((directories
                (catch #t
                  (lambda ()
                    (read (open-input-string
                           (string-drop line (string-length marker)))))
                  (lambda arguments '()))))
           (and (list? directories)
                (find (lambda (directory)
                        (and (string? directory)
                             (file-exists?
                              (string-append
                               directory
                               "/jointhefreeworld/packages/applications.scm"))))
                      directories))))))

(define (test-load-path)
  "Return a GUILE_LOAD_PATH that lets the suite import the channel, or #f.

The pulled guix's profile is the cheap answer, and the right one on a
machine a person uses.  When it is not there, the guix that pinned the
channels is asked (see above)."
  (let* ((guix (pulled-guix))
         (profile (and (not (string=? guix "guix"))
                       (dirname (dirname guix))))
         (site (and profile
                     (format #f "~a/share/guile/site/3.0" profile))))
    (if (and site (file-exists? site))
        site
        (guix-channel-module-directory))))

(define (test)
  "Run the Veritas unit-test suite, one process per test file.

Runs inside the manifest shell like the other Scheme tasks: the suite
imports (guix gexp) and (gnu services ...) and needs veritas, none of
which are in the machine's system profile, so a bare `guile' fails with
`no code for module (veritas runner)' -- which is what the Byggsteg CI
task `maak-test' used to hit.

The files run in parallel, one process each, in as many processes as
this machine may use up to four; VERITAS_JOBS overrides that count.
Four things are deliberate, so that a failure here is a failure of the
code under test rather than of the schedule:

  - the order the files run in is shuffled, and the seed is printed:
    `VERITAS_SEED=<the seed> VERITAS_SHUFFLE_FILES=true maak test'
    replays a failing order, and `VERITAS_SHUFFLE_FILES=false' runs them
    in the fixed one;
  - every fixture is created under a name unique to the run and removed
    when it ends (see test/veritas/temp.scm), so two workers -- or two CI
    jobs sharing /tmp -- cannot collide on one;
  - GUILE_LOAD_PATH names the channel's module directory, because
    evaluating config.scm needs the jointhefreeworld channel and the pinned
    shell does not carry it -- worked out from the pulled guix when there is
    one and from the guix that pinned the channels when there is not (see
    the comments above);
  - a suite that needs the network or the machine's own root-only files
    is a suite that fails for reasons nobody can act on, and there is
    none of those: see the Commentary of each spec."
  (let* ((jobs (test-jobs))
         ;; The tests need the jointhefreeworld channel on their load path;
         ;; see `test-load-path' above for why it has to be worked out
         ;; rather than assumed, and why `guix shell' prepending its own
         ;; profile to it is the order we want: the pinned libraries stay
         ;; first and the channel's modules follow.
         (load-path (test-load-path)))
    (time-machine-manifest-shell
     ;; The suite runs under `env' for two variables that must reach Guile and
     ;; nothing else.  GUILE_LOAD_PATH cannot be one of them -- `guix shell'
     ;; has to see it to append the channel after the pinned profile -- so it
     ;; stays in #:env below; these two belong to the interpreter.
     ;;
     ;; Bytecode in Guile's auto-compilation cache (normally
     ;; ~/.cache/guile/ccache) is keyed by source path, and nothing in that
     ;; key names the Guile revision whose macros expanded the file.  So a
     ;; spec, or config.scm, compiled while channels.scm pinned one Guix is a
     ;; plain cache hit after `maak guix-pull' moves the pin, and expanding
     ;; its old record macros against the new records stops the run with
     ;; "record ABI mismatch; recompilation needed" -- in a file nobody
     ;; touched.
     ;;
     ;; GUILE_AUTO_COMPILE=0 alone does not help: it stops Guile from
     ;; *compiling*, not from *loading* a cached .go that is at least as
     ;; recent as its source (`fresh-compiled-thunk' in ice-9/boot-9.scm
     ;; returns that thunk before it ever looks at the flag).  The cache must
     ;; also be somewhere else, and this path is never created: with
     ;; compilation off nothing writes it, every lookup misses, and the few
     ;; .scm files of this checkout are simply interpreted -- about a second,
     ;; next to a suite that imports all of (gnu services), while the store's
     ;; modules still load compiled.
     ;;
     ;; XDG_CACHE_HOME is deliberately not put on the `guix time-machine'
     ;; command itself: Guix keeps the channel checkouts under the same
     ;; variable, and a per-run value there would re-clone the channels on
     ;; every test run.
     (list "env"
           "GUILE_AUTO_COMPILE=0"
           (format #f "XDG_CACHE_HOME=~a/wolk-jjba-test-~a-cache"
                   (or (getenv "TMPDIR") "/tmp") (getpid))
           "guile" "-L" "./src" "-L" "./test"
           "-c" "'(use-modules (veritas runner)) (run-tests)'")
     #:env (append (list (format #f "VERITAS_JOBS=~a" jobs))
                   (if load-path
                       (list (format #f "GUILE_LOAD_PATH=~a" load-path))
                       '())))))

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
