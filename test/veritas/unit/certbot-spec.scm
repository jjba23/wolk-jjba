;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (wolk-jjba certbot).  Two kinds of question are asked
;; here: what a certificate request looks like (domains, apex and www,
;; the reload hook) and whether the set of certificates still matches the
;; set of TLS vhosts nginx serves.  A certificate without a vhost is
;; wasted rate limit; a vhost without a certificate is a browser warning.

;;; Code:

(define-module (veritas unit certbot-spec)
  #:use-module (veritas veritas)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (gnu services)
  #:use-module (gnu services certbot)
  #:use-module (gnu services web)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-1)
  #:use-module (wolk-jjba certbot)
  #:use-module (wolk-jjba nginx)
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

;; Guix exports the certbot records but not their accessors, so the tests
;; reach for them the way the service compiler does.
(define certificates-of
  (@@ (gnu services certbot) certbot-configuration-certificates))
(define email-of (@@ (gnu services certbot) certbot-configuration-email))
(define webroot-of (@@ (gnu services certbot) certbot-configuration-webroot))
(define domains-of
  (@@ (gnu services certbot) certificate-configuration-domains))
(define deploy-hook-of
  (@@ (gnu services certbot) certificate-configuration-deploy-hook))

(define capability (service-value (certbot-capability)))
(define certificates (certificates-of capability))

(define all-domains (append-map domains-of certificates))

(define (tls-server-names)
  "Every name the TLS vhosts answer for, with the certificates removed."
  (let* ((blocks (nginx-configuration-server-blocks
                  (service-value (nginx-capability))))
         (tls (filter (lambda (block)
                        (member "443 ssl"
                                (nginx-server-configuration-listen block)))
                      blocks)))
    (append-map nginx-server-configuration-server-name tls)))

(define without-www
  (make-site-cert #:domain "naked.example" #:with-www? #f))

(define certbot-suite
  (suite "Certbot Suite"

         (test "A certificate request covers the apex and its www"
               (assert-equal #:expect '("example.org" "www.example.org")
                             #:got (domains-of
                                    (make-site-cert #:domain "example.org"))
                             #:name "The www alias is requested by default")
               (assert-equal #:expect '("naked.example")
                             #:got (domains-of without-www)
                             #:name "with-www? #f requests the apex alone"))

         (test "Every certificate reloads nginx"
               (assert-true (and (every deploy-hook-of certificates) #t)
                            #:name "A deploy hook is attached to each request")
               (assert-true (and (every (lambda (certificate)
                                          (eq? (deploy-hook-of certificate)
                                               cert-nginx-deploy-hook))
                                        certificates)
                                 #t)
                            #:name "All of them are the one nginx reload hook")
               ;; Guix does not export the program-file accessors, so the
               ;; hook is read through its printed form, which carries the
               ;; gexp it was built from.
               (assert-true (and (string-contains (object->string
                                                   cert-nginx-deploy-hook)
                                                  "/var/run/nginx/pid")
                                 #t)
                            #:name "The hook reads nginx's pid file")
               (assert-true (and (string-contains (object->string
                                                   cert-nginx-deploy-hook)
                                                  "SIGHUP")
                                 #t)
                            #:name "The hook reloads nginx with SIGHUP"))

         (test "The capability keeps the documented account and webroot"
               (assert-equal #:expect "jjbigorra@gmail.com"
                             #:got
                             (email-of capability)
                             #:name "The ACME account address is set")
               (assert-equal #:expect "/srv/http"
                             #:got
                             (webroot-of capability)
                             #:name
                             "HTTP-01 challenges are answered from /srv/http"))

         (test "Fifteen certificates are requested"
               (assert-equal #:expect 15
                             #:got (length certificates)
                             #:name "The count matches the list in the module")
               (assert-equal #:expect (length all-domains)
                             #:got (length (delete-duplicates all-domains))
                             #:name "No domain is requested twice"))

         (test "Each vhost has a certificate"
               (assert-equal #:expect '()
                             #:got
                             (remove (lambda (name)
                                       (member name all-domains))
                                     (delete-duplicates (tls-server-names)))
                             #:name
                             "Every TLS vhost name is covered by a certificate"))

         (test "Each certificate has a vhost"
               (assert-equal #:expect '()
                             #:got
                             (remove (lambda (name)
                                       (member name (tls-server-names)))
                                     (delete-duplicates all-domains))
                             #:name
                             "No certificate is requested for an unserved name"))))

(define (spec)
  (veritas-run certbot-suite))
