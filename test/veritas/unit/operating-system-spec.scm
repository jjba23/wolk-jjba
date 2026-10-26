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

;;; Commentary:
;;
;; The whole point of config.scm is that it evaluates, and the failures
;; that matter are the ones that only show up at evaluation time: a
;; capability that is wired to the wrong service type, a gexp that
;; references a variable that no longer exists, a secret file that is
;; read from a path nobody creates.  So this suite evaluates the file
;; for real, in a child Guile, with WOLK_JJBA_SECRETS pointing at
;; fixtures it writes itself -- no root, and no touching /etc/secrets.
;;
;; The evaluation happens in a child process rather than by loading
;; config.scm into this module, because the file imports a large part of
;; (gnu services) and would shadow the names this suite needs.  The child
;; gets the fixture as its secrets directory, so the result does not
;; depend on whether the machine running the tests has a /etc/secrets of
;; its own -- and when the child cannot evaluate at all, every test that
;; needs its answer fails by name instead of the file aborting with a
;; `list-ref' nobody can trace.

;;; Code:

(define-module (veritas unit operating-system-spec)
  #:use-module (veritas veritas)
  #:use-module (veritas temp)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (spec))

(define (read-all port)
  "Return everything PORT yields as a string."
  (let loop ((lines '()))
    (let ((line (read-line port)))
      (if (eof-object? line)
          (string-concatenate-reverse lines)
          (loop (cons (string-append line "\n") lines))))))

(define (make-fixture-directory)
  "Create a directory holding the secrets config.scm reads.

Four files: the two MPD passwords and the two Icecast ones.  A missing
one fails the evaluation, which is the point -- the real machine cannot
start the radio without them either.

The directory comes from (veritas temp), so its name is unique to this
run.  It used to be /tmp/wolk-jjba-spec-<pid>-<seconds> and created with
a bare `mkdir', which made this file fail *while it was loading* -- with
no test named -- whenever another run had chosen the same name."
  (let ((directory (make-temporary-directory "wolk-jjba-spec"))
        (entries '(("mpd-admin" . "fixture-admin-password")
                   ("mpd-read" . "fixture-read-password")
                   ("icecast-source" . "fixture-source-password")
                   ("icecast-admin" . "fixture-icecast-admin-password"))))
    (for-each (lambda (entry)
                (call-with-output-file (format #f "~a/~a"
                                               directory (car entry))
                  (lambda (port)
                    (display (cdr entry) port)
                    (newline port))))
              entries)
    directory))

(define fixtures (make-fixture-directory))

(define (config-expression)
  "The child program: evaluate config.scm and print what it produced."
  (format #f
          "(use-modules (gnu) (guix) (gnu system locale))
(load ~s)
(write (list (operating-system? wolk-jjba-os)
             (operating-system-host-name wolk-jjba-os)
             mpd-admin-password
             mpd-read-password
             (length (operating-system-services wolk-jjba-os))
             (map locale-definition-name
                  (operating-system-locale-definitions wolk-jjba-os))))"
          (string-append (getcwd) "/config.scm")))

(define module-directory-suffix
  ;; Where a Guix profile keeps the modules of its packages.  The 3.0 is
  ;; the Guile the machine runs (see the pinned channels).
  "/share/guile/site/3.0")

(define (compiled-sibling directory)
  "Return the site-ccache that belongs to DIRECTORY, or #f.

A profile lays its modules out as share/guile/site/3.0 and what was
compiled from them as lib/guile/3.0/site-ccache.  Guile searches the
compiled path *before* the load path, so a module and its compiled form
have to come from the same revision: mixing them makes Guile expand the
records of one Guix with the macros of another and stop at

  record ABI mismatch; recompilation needed

which is the failure this suite produces whenever the child is left to a
search path more inventive than a single tree."
  (if (string-suffix? module-directory-suffix directory)
      (let ((ccache (string-append
                     (string-drop-right directory
                                        (string-length module-directory-suffix))
                     "/lib/guile/3.0/site-ccache")))
        (and (file-exists? ccache) ccache))
      #f))

(define (pinned-module-directory)
  "Return the pinned profile's module directory, or #f.

`guix shell' puts it on %load-path as a /gnu/store path, and that Guix is
the one the machine runs and the one the suite is written against."
  (find (lambda (directory)
          (and (string-prefix? "/gnu/store/" directory)
               (string-suffix? module-directory-suffix directory)))
        %load-path))

(define channel-module-marker
  ;; The file that says a directory holds the channel.  Nothing else in a
  ;; Guix profile has this path.
  "/jointhefreeworld/packages/applications.scm")

(define (channel-directory? directory)
  "Return #t when DIRECTORY holds the jointhefreeworld channel."
  (and (string? directory)
       (file-exists? (string-append directory channel-module-marker))
       directory))

(define (channel-module-directory)
  "Return the directory the channel can be imported from, or #f.

config.scm imports (wolk-jjba packages), which imports
(jointhefreeworld packages applications), and that module is not in the
pinned shell's profile: it comes either from the guix profile in $HOME
(where `guix pull --channels=channels.scm' installs it) or, on a machine
that has no such profile -- a CI job running as root, whose guix is the
one in the system profile -- from the module directory that `maak test'
worked out and exported.  So this asks the load path the suite was started
with first, and only then $HOME.

The answer is canonicalized: both the pulled profile and the store path the
pinned channels use may be reached through a symlink, and Guile's
compilation cache is keyed by the path it loaded a module from, so the same
symlink would keep serving compiled files from an older revision."
  (let ((home (or (getenv "HOME") "")))
    (canonicalize-path
     (or (find channel-directory? %load-path)
         (find channel-directory?
               (map (lambda (profile)
                      (string-append profile module-directory-suffix))
                    (list (string-append home "/.config/guix/current")
                          (string-append home "/.guix-profile"))))))))

(define (evaluate-config secrets-directory)
  "Evaluate config.scm with WOLK_JJBA_SECRETS set to SECRETS-DIRECTORY.

The child gets one tree, explicitly, and nothing else: `-L ./src' for this
repository, the pinned profile for Guix and its libraries, the channel's
profile for (jointhefreeworld ...), a compiled path that belongs to the
pinned profile alone, and no inherited GUILE_LOAD_PATH.  Auto-compilation is
off as well, and the cache is pointed at a directory that does not exist,
for the same reason: Guile's cache is keyed by source path only, so a
config.scm.go compiled while channels.scm pinned an older Guix is still
loaded after `maak guix-pull' moves the pin -- `GUILE_AUTO_COMPILE=0'
disables compilation, not the loading of a .go that looks fresh to
`fresh-compiled-thunk' -- and expanding its old record macros against the
new records stops the child with `record ABI mismatch; recompilation
needed'.  Interpreting config.scm costs about a second; trusting a cache
that cannot tell two Guix revisions apart costs the whole suite.

That is the whole point of the list.  The environment the suite is started
in is not one tree: `guix shell' puts the pinned profile first and then the
profiles in $HOME, which hold other Guix revisions, and Guile resolves a
module's *source* and its *compiled* form through two different paths.  A
child that inherits that can end up loading compiled code from one revision
and expanding it with the macros of another -- `record ABI mismatch;
recompilation needed' -- and which pair it picks depends on what the parent
process happened to have loaded already, which is why the same suite passed
in one invocation and failed in another.

WOLK_JJBA_SECRETS is set for the child alone: the fixture must be the only
secrets directory the evaluation sees, whether or not the machine running
the tests has one of its own.

Return a pair of the exit status and whatever the child printed."
  (let* ((pinned (pinned-module-directory))
         (channel (channel-module-directory))
         (compiled (and pinned (compiled-sibling pinned)))
         (port (apply open-pipe* OPEN_READ
                      (append (list "env"
                                    "-u" "GUILE_LOAD_PATH"
                                    "GUILE_AUTO_COMPILE=0"
                                    ;; Never created: see above.
                                    (format #f "XDG_CACHE_HOME=~a/ccache"
                                            fixtures)
                                    (format #f "GUILE_LOAD_COMPILED_PATH=~a"
                                            (or compiled ""))
                                    (format #f "WOLK_JJBA_SECRETS=~a"
                                            secrets-directory)
                                    "guile" "-L" "./src")
                              (append (if pinned (list "-L" pinned) '())
                                      (if channel (list "-L" channel) '()))
                              (list "-c" (config-expression)))))
         (output (read-all port))
         (status (close-pipe port)))
    (cons status output)))

(define evaluation (evaluate-config fixtures))

;; The answer to give every test when the child could not answer at all.
;;
;; Without it, a failed evaluation -- the interesting case -- made the
;; first test pass by accident (a non-zero status is not zero) and then
;; had `list-ref' raise inside the next one, which aborts the whole file
;; with `❌ error - aborting due to error in test case...', no test named
;; and no expectation printed.  A list of placeholders fails every test
;; that depends on the evaluation, one by one, saying which one.
(define missing-result
  (list #f "(the child did not evaluate config.scm)" "" "" 0 '()))

(define result
  (if (zero? (car evaluation))
      (catch #t
        (lambda ()
          (with-input-from-string (cdr evaluation) read))
        (lambda arguments
          missing-result))
      missing-result))

(define missing-secrets-evaluation
  ;; A sibling of the fixture, so it is guaranteed not to exist: the old
  ;; path was a fixed /tmp name, and a test that asserts "this directory
  ;; is missing" fails on a machine where something left it behind.
  (evaluate-config (string-append fixtures "/no-such-directory")))

(define operating-system-suite
  (suite "Operating System Suite"

         (test "The system configuration evaluates as an ordinary user"
               (assert-equal #:expect 0
                             #:got (car evaluation)
                             #:name "config.scm evaluates without root")
               (assert-equal #:expect "wolk-jjba"
                             #:got (list-ref result 1)
                             #:name "The host keeps its name")
               (assert-true (and (list-ref result 0) #t)
                            #:name "The result is an operating-system"))

         (test "The passwords come from the secrets directory the environment names"
               (assert-equal #:expect "fixture-admin-password"
                             #:got (list-ref result 2)
                             #:name "The admin password is the fixture's")
               (assert-equal #:expect "fixture-read-password"
                             #:got (list-ref result 3)
                             #:name "The read password is the fixture's"))

         (test "The machine still has its services"
               (assert-true (> (list-ref result 4) 50)
                            #:name "The service list is the whole machine"))

         (test "The languages a visitor may ask for are compiled"
               ;; A language only works when glibc has its locale: without
               ;; one, a process falls back to C and gettext transliterates
               ;; every message to "?".  These are the ones the sites
               ;; offer or are about to; the catalogs themselves live in
               ;; each application.
               (assert-equal #:expect '(#t #t #t #t #t #t)
                             #:got (map (lambda (name)
                                          (and (member name (list-ref result 5))
                                               #t))
                                        '("ja_JP.utf8" "el_GR.utf8"
                                          "zh_TW.utf8" "zh_CN.utf8"
                                          "ar_SA.utf8" "ru_RU.utf8"))
                             #:name "Japanese, Greek, Chinese (both scripts), Arabic and Russian"))

         (test "A missing secrets directory fails the evaluation"
               (assert-true (not (zero? (car missing-secrets-evaluation)))
                            #:name "config.scm cannot silently ship without secrets"))))

(define (spec)
  ;; The fixture holds fake passwords, so it goes when the run does.  Not
  ;; on every exit path: `veritas-run' calls `exit' when a suite fails, and
  ;; nothing runs after that in Guile 3 -- `exit-hook' is a hook nothing
  ;; fires -- so a *failed* run leaves one directory behind.  That is
  ;; harmless because the name is unique to the run (see (veritas temp));
  ;; the alternative, sweeping /tmp for leftovers, would delete the fixture
  ;; of a run that is still using it.
  (dynamic-wind
    (lambda () #t)
    (lambda () (veritas-run operating-system-suite))
    (lambda () (remove-directory-tree fixtures))))
