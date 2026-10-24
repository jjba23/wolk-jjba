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

(define (channel-module-directories)
  "Return the directories that may hold the jointhefreeworld channel.

config.scm imports (wolk-jjba packages), which imports
(jointhefreeworld packages applications), and those modules are not in the
pinned shell's profile: `guix pull --channels=channels.scm' installs them
into the Guix profile in $HOME (see README, \"Quick start\").  The suite
process may or may not see that directory, depending on how it was started
-- `maak' unsets GUILE_LOAD_PATH on purpose before it runs anything -- so
the child is told about it explicitly instead.  Without this the
evaluation stops at

  no code for module (jointhefreeworld packages applications)

which reads like a broken channel and only happens on some invocations."
  (let ((home (or (getenv "HOME") "")))
    (filter file-exists?
            (list (string-append home
                                 "/.config/guix/current/share/guile/site/3.0")
                  (string-append home
                                 "/.guix-profile/share/guile/site/3.0")))))

(define (module-path-arguments)
  "Return one -L argument per directory the child needs to import anything.

The child is handed the load path instead of inheriting it: this process's
%load-path is what the suite itself imported from (Guix and the pinned
shell's libraries), and `channel-module-directories' is what config.scm
additionally needs.  Both, explicitly, so the evaluation does not depend
on what the environment looks like by the time the child runs."
  (append-map (lambda (directory)
                (list "-L" directory))
              (delete-duplicates
               (append %load-path (channel-module-directories))
               string=?)))

(define (evaluate-config secrets-directory)
  "Evaluate config.scm with WOLK_JJBA_SECRETS set to SECRETS-DIRECTORY.

The child gets an explicit load path (see `module-path-arguments'), so it
imports Guix and the jointhefreeworld channel from the same trees the suite
itself was imported from.

The one variable that is *set*, not inherited, is WOLK_JJBA_SECRETS: the
fixture must be the only secrets directory the evaluation sees, whether or
not the machine running the tests has one of its own.

Return a pair of the exit status and whatever the child printed."
  (let* ((port (apply open-pipe* OPEN_READ
                      (append (list "env"
                                    (format #f "WOLK_JJBA_SECRETS=~a"
                                            secrets-directory)
                                    "guile")
                              (module-path-arguments)
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
