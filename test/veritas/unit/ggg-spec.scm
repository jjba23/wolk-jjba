;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (wolk-jjba ggg).  The daemon is the only part of the
;; badge server the system can check without starting it: the command
;; line, the loopback bind and the port are read from the service's
;; start expression, and the package pin is checked because Guix's own
;; ggg predates --serve.

;;; Code:

(define-module (veritas unit ggg-spec)
  #:use-module (veritas veritas)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (gnu services shepherd)
  #:use-module (wolk-jjba ggg)
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

(define service
  (car (wolk-jjba-ggg-server-service)))

(define start
  (gexp->approximate-sexp (shepherd-service-start service)))

(define ggg-suite
  (suite "GGG Suite"

         (test "ggg runs as a respawning Shepherd daemon"
               (assert-equal #:expect '(ggg-server)
                             #:got (shepherd-service-provision service)
                             #:name "The service is provisioned as ggg-server")
               (assert-true (and (memq 'networking
                                       (shepherd-service-requirement service))
                                 #t)
                            #:name "It starts after networking")
               (assert-true (shepherd-service-respawn? service)
                            #:name "It comes back when it dies"))

         (test "The daemon serves badges on loopback"
               (assert-true (tree-contains? start "--serve")
                            #:name "The server mode is selected")
               (assert-true (tree-contains? start "--host")
                            #:name "The bind address is explicit")
               (assert-true (tree-contains? start "127.0.0.1")
                            #:name "It binds loopback only")
               (assert-true (tree-contains? start "--port")
                            #:name "The port is explicit")
               (assert-true (tree-contains? start "50055")
                            #:name "It uses the documented port"))

         (test "The package is the release that has --serve"
               (assert-equal #:expect "ggg"
                             #:got (package-name ggg-package)
                             #:name "The package is named ggg")
               (assert-equal #:expect "0.17.1"
                             #:got (package-version ggg-package)
                             #:name "The pin is the first release with the server"))))

(define (spec)
  (veritas-run ggg-suite))
