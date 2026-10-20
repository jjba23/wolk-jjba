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
;; Unit tests for (wolk-jjba logging).  The destination procedure runs
;; inside the Shepherd, where the system-log records live, so it is read
;; rather than called: the tests lower it with
;; `gexp->approximate-sexp' and check the routing table it contains -- and
;; that the capability actually replaces the Shepherd's default
;; destination, which is the part that silently does nothing if it is
;; wired up wrongly.

;;; Code:

(define-module (veritas unit logging-spec)
  #:use-module (veritas veritas)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (srfi srfi-1)
  #:use-module (wolk-jjba logging)
  #:export (spec))

(define (tree-contains? tree needle)
  "Return #t when NEEDLE occurs anywhere in the nested list TREE."
  (cond
    ((null? tree) #f)
    ((pair? tree) (or (tree-contains? (car tree) needle)
                      (tree-contains? (cdr tree) needle)))
    ((vector? tree) (tree-contains? (vector->list tree) needle))
    ((equal? tree needle) #t)
    (else #f)))

(define base-service (service shepherd-system-log-service-type))

(define reconfigured
  (find (lambda (service)
          (eq? (service-kind service) shepherd-system-log-service-type))
        (system-log-capability (list base-service))))

(define destination
  (system-log-configuration-message-destination
   (service-value reconfigured)))

(define destination-sexp (gexp->approximate-sexp destination))

(define logging-suite
  (suite "Logging Suite"

         (test "The capability replaces the Shepherd's destination"
               (assert-true (and reconfigured #t)
                            #:name "The system log service survives the rewrite")
               (assert-true (eq? destination wolk-jjba-message-destination)
                            #:name
                            "The configured destination is this module's procedure")
               (assert-false (eq? destination
                                  (system-log-configuration-message-destination
                                   (service-value base-service)))
                             #:name
                             "It is not the default catch-all destination"))

         (test "Urgent messages reach the console"
               (assert-true (tree-contains? destination-sexp "/dev/console")
                            #:name "emergency and alert are written to /dev/console")
               (assert-true (tree-contains? destination-sexp 'emergency)
                            #:name "The emergency priority is named in the table")
               (assert-true (tree-contains? destination-sexp 'alert)
                            #:name "The alert priority is named in the table")
               (assert-true (tree-contains? destination-sexp
                                            'system-log-priority)
                            #:name "Priorities are read through the Shepherd"))

         (test "AUTH, mail and cron have their own files"
               (assert-true (tree-contains? destination-sexp "/var/log/auth.log")
                            #:name "Authentication goes to auth.log")
               (assert-true (tree-contains? destination-sexp "/var/log/mail.log")
                            #:name "Mail goes to mail.log")
               (assert-true (tree-contains? destination-sexp "/var/log/cron.log")
                            #:name "Scheduled jobs go to cron.log")
               (assert-true (tree-contains? destination-sexp "/var/log/kern.log")
                            #:name "Kernel messages go to kern.log")
               (assert-true (tree-contains? destination-sexp
                                            "/var/log/daemon.log")
                            #:name "Daemon messages go to daemon.log"))

         (test "Everything else lands in the catch-all"
               (assert-true (tree-contains? destination-sexp "/var/log/messages")
                            #:name "There is a catch-all file")
               (assert-true (tree-contains? destination-sexp
                                            'authorization/private)
                            #:name "Private authorization messages are routed too")
               (assert-true (tree-contains? destination-sexp
                                            'system-log-facility)
                            #:name "Facilities are read through the Shepherd"))

         (test "The capability is a rewriting function, not a service"
               (assert-equal #:expect 1
                             #:got (length (system-log-capability
                                            (list base-service)))
                             #:name "The service list it is given comes back"))))

(define (spec)
  (veritas-run logging-suite))
