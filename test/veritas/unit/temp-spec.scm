;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (veritas temp), the fixture directories the suite makes.
;;
;; This is test infrastructure testing itself, which is worth a file because
;; the failure it prevents is invisible: a fixture that two runs pick at the
;; same time fails while a spec file is being *loaded*, so the run reports
;; `❌ error - aborting due to error in test case...' with no test named, and
;; it goes away when run again.  That is the shape of every "flaky in CI,
;; fine locally" report this suite has had.
;;
;; The properties that matter, and that a regression would break:
;;
;;   - two calls never return the same directory, even in the same second
;;     and from the same process -- the counter is what does that, and
;;     twenty calls inside one second are one second of no counter;
;;   - a directory that is already there is never an error and never
;;     reused (asking for a fixture must not hand back somebody else's
;;     files);
;;   - removal takes a whole tree with it, and a missing path is not an
;;     error: it runs at the end of a suite, where a second failure helps
;;     nobody.
;;
;; Code:

(define-module (veritas unit temp-spec)
  #:use-module (veritas veritas)
  #:use-module (veritas temp)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (spec))

(define (file-mode path)
  "Return the permission bits of PATH as a number."
  (logand (stat:perms (stat path)) #o777))

;; The directories this suite made, so it can take them away again.
(define temporary-directories '())

(define* (make! prefix #:key root)
  "Create a fixture directory and remember it for the cleanup."
  (let ((path (if root
                  (make-temporary-directory prefix #:root root)
                  (make-temporary-directory prefix))))
    (set! temporary-directories (cons path temporary-directories))
    path))

(define (unique? list)
  "Return #t when every element of LIST is different from every other."
  (= (length list) (length (delete-duplicates list))))

(define temp-suite
  (suite "Temporary Directory Suite"

         (test "Two calls never make the same directory"
               ;; Twenty in a row are made in the same second, which is
               ;; exactly the case the old <pid>-<seconds> name got wrong:
               ;; one run's second call was the previous call's name.
               (let ((made (map (lambda (index)
                                  (make! "wolk-jjba-temp-spec"))
                                (iota 20))))
                 (assert-true (unique? made)
                              #:name "Every fixture has a name of its own")
                 (assert-true (every (lambda (path)
                                       (and (file-exists? path)
                                            (file-is-directory? path)))
                                     made)
                              #:name "And every one of them was created")
                 (assert-true (every (lambda (path)
                                       ;; `scandir' always lists "." and
                                       ;; "..", so an empty directory is
                                       ;; two entries long.
                                       (null? (drop (scandir path) 2)))
                                     made)
                              #:name "Each starts empty, so no run inherits files")
                 (assert-true (every (lambda (path)
                                       (= #o700 (file-mode path)))
                                     made)
                              #:name "And none of them is readable by another user")))

         (test "The directory is named after the fixture, in TMPDIR"
               ;; The name is the one thing a leftover in /tmp has to say
               ;; for itself, and TMPDIR is how a runner redirects
               ;; temporary files off a small disk.
               (let* ((root (make! "wolk-jjba-temp-root"))
                      (inside (make! "wolk-jjba-temp-spec" #:root root)))
                 (assert-true (and (string-contains inside
                                                    "/wolk-jjba-temp-spec-")
                                   #t)
                              #:name "The prefix names the suite that made it")
                 (assert-true (string=? root (dirname inside))
                              #:name "And it is created in the directory asked for")))

         (test "A directory that is already there is never handed out"
               ;; The point of the counter: a call made while directories
               ;; exist -- the same suite asking twice, another worker, a
               ;; second CI job -- gets a new, empty directory and never
               ;; somebody else's files.
               (let* ((first (make! "wolk-jjba-temp-existing"))
                      (stale (string-append first "/stale")))
                 (call-with-output-file stale
                   (lambda (port)
                     (display "left by another run" port)))
                 (let ((second (make! "wolk-jjba-temp-existing")))
                   (assert-true (not (string=? first second))
                                #:name "The second call chose another name")
                   (assert-true (not (file-exists?
                                      (string-append second "/stale")))
                                #:name "The new fixture does not inherit the last run's files")
                   (assert-true (file-exists? stale)
                                #:name "And the directory that was there is left alone"))))

         (test "Removal takes the whole tree, and a missing path is fine"
               (let* ((root (make! "wolk-jjba-temp-removal"))
                      (nested (string-append root "/a/b"))
                      (file (string-append nested "/c")))
                 (mkdir (string-append root "/a") #o700)
                 (mkdir nested #o700)
                 (call-with-output-file file
                   (lambda (port)
                     (display "fixture" port)))
                 (assert-true (remove-directory-tree root)
                              #:name "Removal reports success")
                 (assert-true (not (file-exists? root))
                              #:name "The tree is gone, not just its files")
                 (assert-true (remove-directory-tree root)
                              #:name "Removing what is not there is not an error")
                 (assert-true (remove-directory-tree
                               (string-append root "/never-existed"))
                              #:name "Neither is a path that never existed")))))

(define (remove-fixtures)
  (for-each remove-directory-tree temporary-directories)
  (set! temporary-directories '()))

(define (spec)
  (dynamic-wind
    (lambda () #t)
    (lambda () (veritas-run temp-suite))
    remove-fixtures))
