;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (wolk-jjba security).
;;
;; What the audit decides is tested in cve-spec: the catalogue matching,
;; the manifest reading and the word normalisation are plain functions
;; there.  What is left here is the wiring, and it is worth its own test
;; because a timer that is defined but never added to the service list is
;; a job that silently never runs -- which is exactly the failure mode a
;; daily audit must not have.  The last test pins the *shape* of the job:
;; a store program rather than a shell string, so the matching runs the
;; code that the suite exercises and not a copy of it.

;;; Code:

(define-module (veritas unit security-spec)
  #:use-module (veritas veritas)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services shepherd)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba security)
  #:export (spec))

(define capability (security-capability))

(define (extension-towards type)
  "Return the extension of the security service that targets TYPE."
  (find (lambda (extension)
          (eq? (service-extension-target extension) type))
        (service-type-extensions (service-kind capability))))

(define timers ((service-extension-compute
                 (extension-towards shepherd-root-service-type))
                '()))

(define rotated-logs ((service-extension-compute
                       (extension-towards log-rotation-service-type))
                      '()))

(define timer (car timers))

(define (contains? haystack needle)
  (and (string-contains haystack needle) #t))

(define security-suite
  (suite "Security Suite"

         (test "The audit is scheduled"
               (assert-equal #:expect '(security-audit)
                             #:got (shepherd-service-provision timer)
                             #:name "One timer is provided, under the name the alerts use")                 (assert-true (eq? (shepherd-service-respawn? timer) #t)
                            #:name "It is kept running by the Shepherd"))

         (test "The audit runs after the network"
               (assert-true (and (memq 'networking
                                       (shepherd-service-requirement timer))
                                 #t)
                            #:name "It fetches the catalogue, so networking is required"))

         (test "The audit's log is rotated"
               (assert-equal #:expect (list "/var/log/wolk-jjba/security-audit.log")
                             #:got rotated-logs
                             #:name "The job log is registered with the rotation service"))

         ;; The audit is a gexp that lowers to a store program (wrapped in
         ;; the guile-json extension), not a shell string: the matching
         ;; must be the code cve-spec exercises, not a copy of it.
         (test "The audit is a program, not a shell string"
               (assert-true (struct? security-audit-program)
                            #:name "The timer is given a lowered object")
               (assert-false (string? security-audit-program)
                             #:name "The matching is not re-implemented in shell"))))

(define (spec)
  (veritas-run security-suite))
