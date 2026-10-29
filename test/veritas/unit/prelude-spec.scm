;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (wolk-jjba prelude): the path conventions every other
;; module follows and the factory that turns a project checkout into a
;; Shepherd daemon.
;;
;; The factory is checked through the service type it returns rather than
;; by starting anything: its extension to shepherd-root-service-type is
;; called the way the service compiler would call it, and the start thunk
;; is lowered with `gexp->approximate-sexp' and searched.
;;
;; Contributor note: `assert-*' are pure constructors.  An assertion that
;; sits in a non-final position of a `let' body has its value discarded,
;; and Guile's optimizer is free to delete the call, so the assertion
;; silently never runs.  The fixtures below are therefore built once at
;; module level, and every assertion is a direct argument of `test'.

;;; Code:

(define-module (veritas unit prelude-spec)
  #:use-module (veritas veritas)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba prelude)
  #:export (spec))

(define (tree-contains? tree needle)
  "Return @code{#t} when NEEDLE occurs anywhere in the nested list TREE."
  (cond
    ((null? tree) #f)
    ((pair? tree) (or (tree-contains? (car tree) needle)
                      (tree-contains? (cdr tree) needle)))
    ((vector? tree) (tree-contains? (vector->list tree) needle))
    ((equal? tree needle) #t)
    (else #f)))

(define (shepherd-service-of service)
  "Return the one shepherd-service SERVICE's extension contributes."
  (car ((service-extension-compute
         (car (service-type-extensions (service-kind service))))
        '())))

(define (start-sexp service)
  (gexp->approximate-sexp
   (shepherd-service-start (shepherd-service-of service))))

(define (environment-of tree)
  "Return the environment strings in TREE, the lowered start thunk.

The thunk is a gexp, so the environment is still the form
@code{(list \"LANG=...\" ...)}; the @code{list} symbol is dropped."
  (cond
    ((null? tree) '())
    ((pair? tree)
     (if (and (eq? (car tree) #:environment-variables)
              (pair? (cdr tree)))
         (let ((value (cadr tree)))
           (if (and (pair? value) (eq? (car value) 'list))
               (cdr value)
               value))
         (let ((found (environment-of (car tree))))
           (if (null? found) (environment-of (cdr tree)) found))))
    ((vector? tree) (environment-of (vector->list tree)))
    (else '())))

(define probe-daemon
  (make-guile-server-shepherd-daemon #:service-name 'probe-daemon
                                     #:provision '(probe-daemon)
                                     #:directory "/srv/probe"
                                     #:documentation "the probe daemon"))

(define probe-service (shepherd-service-of probe-daemon))
(define probe-start (start-sexp probe-daemon))
(define probe-env (environment-of probe-start))

(define named-daemon
  (make-guile-server-shepherd-daemon #:service-name 'named-daemon
                                     #:provision '(named-daemon)
                                     #:directory "/tmp"
                                     #:documentation "documented"))

(define relocated-daemon
  (make-guile-server-shepherd-daemon #:service-name 'relocated-daemon
                                     #:provision '(relocated-daemon)
                                     #:directory "/tmp"
                                     #:documentation "moved log"
                                     #:log-file "/tmp/somewhere-else.log"))

(define default-sandbox
  (make-guile-server-shepherd-daemon #:service-name 'sandbox
                                     #:provision '(sandbox)
                                     #:directory "/tmp"
                                     #:documentation "sandbox"))

(define prelude-suite
  (suite "Prelude Suite"

         (test "Managed projects live under one checkout tree"
               (assert-equal #:expect "/etc/byggsteg/job-clone/lucidplan/trunk"
                             #:got (byggsteg-managed-project-dir 'lucidplan)
                             #:name "The default branch is trunk")
               (assert-equal #:expect "/etc/byggsteg/job-clone/wikimusic/experiment"
                             #:got (byggsteg-managed-project-dir 'wikimusic
                                                                 #:branch
                                                                 'experiment)
                             #:name "A non-default branch is honoured")
               (assert-equal #:expect "/etc/byggsteg/job-clone/byggsteg/trunk"
                             #:got (byggsteg-managed-project-dir 'byggsteg)
                             #:name "The name may be any symbol"))

         (test "Per-daemon logs share one directory"
               (assert-equal #:expect "/var/log/wolk-jjba"
                             #:got wolk-jjba-log-directory
                             #:name "The log directory is the one Alloy tails"))

         (test "A daemon is a respawning, auto-started shepherd service"
               (assert-equal #:expect '(probe-daemon)
                             #:got (shepherd-service-provision probe-service)
                             #:name "The provision name is the daemon name")
               (assert-true (shepherd-service-respawn? probe-service)
                            #:name
                            "A crashed daemon must be respawned by the Shepherd")
               (assert-true (shepherd-service-auto-start? probe-service)
                            #:name "A daemon starts with the system")
               (assert-equal #:expect '()
                             #:got
                             (shepherd-service-requirement probe-service)
                             #:name "The factory imposes no ordering of its own"))

         (test "The daemon logs to its own file, not the system log"
               (assert-true (tree-contains? probe-start
                                            "/var/log/wolk-jjba/probe-daemon.log")
                            #:name "The log file is named after the daemon")
               (assert-true (tree-contains? probe-start "/var/log/wolk-jjba")
                            #:name "The log directory is created before exec")
               (assert-true (tree-contains? probe-start #:log-file)
                            #:name "The file is handed to #:log-file"))

         (test "The daemon runs maak in the project directory"
               (assert-true (tree-contains? probe-start "production-server")
                            #:name "The default command is make production-server")
               (assert-true (tree-contains? probe-start "make")
                            #:name "The command is maak, run through make")
               (assert-true (tree-contains? probe-start "/srv/probe")
                            #:name "The project directory is the working one")
               (assert-true (tree-contains? probe-start #:directory)
                            #:name "A working directory reaches the constructor"))

         (test "The daemon environment carries a UTF-8 locale"
               ;; Regression test: without LANG the process runs in the C
               ;; locale, whose codeset is ASCII, and GNU gettext
               ;; transliterates every translated string to "?" before it
               ;; reaches a page.  See the comment in (wolk-jjba prelude).
               (assert-true (and (member "LANG=en_US.utf8" probe-env) #t)
                            #:name "LANG is set for every application daemon")
               (assert-false (and (member "LC_ALL=C" probe-env) #t)
                             #:name "Nothing forces the C locale")
               (assert-true (and (member "GUILE_LOAD_PATH=/run/current-system/profile/share/guile/site/3.0"
                                      probe-env)
                               #t)
                            #:name "Guile finds the system's modules")
               (assert-equal #:expect 11
                             #:got (length probe-env)
                             #:name "The environment is the declared eleven")
               (assert-true (any (lambda (entry)
                                   (string-prefix? "PATH=" entry))
                                 probe-env)
                            #:name "A PATH is passed, so make and guile resolve"))

         (test "The log file can be overridden"
               (assert-true (tree-contains? (start-sexp relocated-daemon)
                                            "/tmp/somewhere-else.log")
                            #:name "The explicit path wins over the convention")
               (assert-false (tree-contains? (start-sexp relocated-daemon)
                                             "/var/log/wolk-jjba/relocated-daemon.log")
                             #:name "The conventional path is not also passed"))

         (test "The factory names its own service type"
               (assert-equal #:expect 'named-daemon
                             #:got
                             (service-type-name (service-kind named-daemon))
                             #:name "The service type is named after the daemon")
               (assert-equal #:expect "documented"
                             #:got
                             (service-type-description
                              (service-kind named-daemon))
                             #:name "The description is the documentation")
               (assert-equal #:expect '()
                             #:got (service-value named-daemon)
                             #:name "The service carries no value of its own"))

         (test "Every factory call yields an independent service type"
               (assert-false (eq? (service-kind default-sandbox)
                                  (service-kind probe-daemon))
                             #:name "Two daemons are two service types"))

         (test "Shell helpers return what the command printed"
               (assert-equal #:expect "hello\n"
                             #:got (with-output-to-string
                                     (lambda () (syscall "printf 'hello\\n'")))))))

(define (spec)
  (veritas-run prelude-suite))
