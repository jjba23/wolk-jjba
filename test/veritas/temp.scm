;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Temporary directories for the test suite.
;;
;; Two suites need a private place to write files: the operating-system
;; one writes the four secrets config.scm reads, and the secrets one needs
;; two homes to chown an auth.json into.  Both used to make that place out
;; of the process id and the current second:
;;
;;   /tmp/wolk-jjba-spec-<pid>-<seconds>
;;
;; which is not unique enough to be a fixture.  `current-time' counts
;; seconds and process ids are reused, and a CI machine runs more than one
;; copy of this suite: one worker process per spec file, two jobs of one
;; pipeline, a job retried while the one it retries is still running.  Two
;; runs that picked the same name got
;;
;;   ERROR: In procedure mkdir: File exists
;;
;; while the spec file was being *loaded*, so instead of a failing
;; assertion the run stopped with
;;
;;   ❌ error - aborting due to error in test case...
;;
;; and no test named at all: a failure that looks like a broken suite,
;; reports nothing useful, and disappears when it is run again.
;;
;; The name now carries a counter and creation retries, `mkdir' being the
;; atomic step, so two runs cannot collide.  Removal is best effort and
;; never raises: it happens while a suite is finishing, which is no place
;; for a second error.
;;
;; This file is deliberately not under test/veritas/unit/: the runner
;; treats every .scm there as a test file and calls its `spec', so a helper
;; parked among them would be run as one.
;;
;; Code:

(define-module (veritas temp)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:export (make-temporary-directory remove-directory-tree))

(define counter 0)

(define* (make-temporary-directory prefix #:key (root #f) (mode #o700))
  "Create and return a new, private, uniquely named directory.

PREFIX names the fixture, so a directory left behind in /tmp says which
suite left it.  ROOT is where to create it: $TMPDIR when that is set, and
/tmp otherwise, which is what a CI runner that redirects temporary files
expects.

The name carries the prefix, the process id, the time and a counter.
A name that is taken is skipped rather than reported, and the `mkdir' is
retried: a directory that exists is either a leftover (it cannot be
removed for us: another run may own it) or the half-microsecond race in
which another process created the same name, and neither is what any test
is about."
  (let ((root (or root (getenv "TMPDIR") "/tmp")))
    (let loop ((attempt 0))
      (when (> attempt 100)
        (error "could not create a temporary directory for a fixture in"
               root))
      (set! counter (+ counter 1))
      (let ((path (format #f "~a/~a-~a-~a-~a"
                          root prefix (getpid) (current-time) counter)))
        (if (file-exists? path)
            (loop (+ attempt 1))
            (catch 'system-error
              (lambda ()
                (mkdir path mode)
                path)
              (lambda (key . arguments)
                ;; Another process won the race after the check above:
                ;; only that case is worth retrying, anything else is a
                ;; real error and is reported as one.
                (if (file-exists? path)
                    (loop (+ attempt 1))
                    (apply throw key arguments)))))))))

(define (remove-directory-tree path)
  "Delete PATH and everything below it, when it is there.

Best effort: this runs at the end of a suite, and a fixture that cannot be
removed is no reason to fail a run that has already made up its mind.
Symlinks are not followed -- `lstat' is what decides whether an entry is a
directory, so a link is unlinked rather than walked into -- and a file that
disappears mid-walk stops that walk, not the suite."
  (catch 'system-error
    (lambda ()
      (cond
       ((not (file-exists? path))
        #t)
       ((eq? 'directory (stat:type (lstat path)))
        (for-each (lambda (name)
                    (unless (member name '("." ".."))
                      (remove-directory-tree (string-append path "/" name))))
                  (scandir path))
        (rmdir path))
       (else
        (delete-file path)))
      #t)
    (lambda arguments #f)))
