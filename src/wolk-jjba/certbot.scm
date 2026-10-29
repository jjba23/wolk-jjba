;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

(define-module (wolk-jjba certbot)
  #:use-module (gnu)
  #:use-module (guix)
  #:export (certbot-capability cert-nginx-deploy-hook
                               make-site-cert
                               jointhefreeworld-certbot-cert
                               carvoeirowaterfun-certbot-cert
                               byggsteg-certbot-cert
                               lucidplan-certbot-cert
                               pingwing-certbot-cert
                               hygguile-certbot-cert
                               wikimusic-certbot-cert
                               wip-site-certbot-cert))

(use-service-modules certbot)

(define cert-nginx-deploy-hook
  (program-file "nginx-deploy-hook"
                #~(let ((pid (call-with-input-file "/var/run/nginx/pid"
                               read)))
                    (kill pid SIGHUP))))

(define* (make-site-cert #:key domain
                         (with-www? #t))
  (certificate-configuration (domains (append (list domain)
                                              (if with-www?
                                                  (list (format #f "www.~a"
                                                                domain))
                                                  '())))
                             (deploy-hook cert-nginx-deploy-hook)))

(define jointhefreeworld-certbot-cert
  (make-site-cert #:domain "jointhefreeworld.org"))

(define symbanta-jointhefreeworld-certbot-cert
  (make-site-cert #:domain "symbanta.jointhefreeworld.org"))

(define api-symbanta-jointhefreeworld-certbot-cert
  (make-site-cert #:domain "api.symbanta.jointhefreeworld.org"
                  #:with-www? #f))

(define carvoeirowaterfun-certbot-cert
  (make-site-cert #:domain "carvoeirowaterfun.com"))

(define byggsteg-certbot-cert
  (make-site-cert #:domain "byggsteg.jointhefreeworld.org"))

(define lucidplan-certbot-cert
  (make-site-cert #:domain "lucidplan.jointhefreeworld.org"))

(define hygguile-certbot-cert
  (make-site-cert #:domain "hygguile.jointhefreeworld.org"))

(define torikomi-certbot-cert
  (make-site-cert #:domain "torikomi.jointhefreeworld.org"))

(define prometheus-certbot-cert
  (make-site-cert #:domain "prometheus.jointhefreeworld.org"))

(define prometheus-exporter-certbot-cert
  (make-site-cert #:domain "prometheus-exporter.jointhefreeworld.org"))

(define grafana-certbot-cert
  (make-site-cert #:domain "grafana.jointhefreeworld.org"))

(define wikimusic-certbot-cert
  (make-site-cert #:domain "wikimusic.jointhefreeworld.org"))

(define pingwing-certbot-cert
  (make-site-cert #:domain "pingwing.jointhefreeworld.org"
                  #:with-www? #f))

(define wip-site-certbot-cert
  (make-site-cert #:domain "wip-site.jointhefreeworld.org"))

(define visus-aeternus-certbot-cert
  (make-site-cert #:domain "visus-aeternus.jointhefreeworld.org"))

;; You may want to use a staging ACME server when testing.
;; (define-public %certbot-server
;;   "https://acme-staging-v02.api.letsencrypt.org/directory")

(define* (certbot-capability #:key (email "jjbigorra@gmail.com")
                             (root "/srv/http"))
  (service certbot-service-type
           (certbot-configuration (email email)
                                  (webroot root)
                                  (certificates (list hygguile-certbot-cert
                                                 carvoeirowaterfun-certbot-cert
                                                 byggsteg-certbot-cert
                                                 lucidplan-certbot-cert
                                                 grafana-certbot-cert
                                                 prometheus-certbot-cert
                                                 prometheus-exporter-certbot-cert
                                                 wikimusic-certbot-cert
                                                 api-symbanta-jointhefreeworld-certbot-cert
                                                 symbanta-jointhefreeworld-certbot-cert
                                                 torikomi-certbot-cert
                                                 visus-aeternus-certbot-cert
                                                 pingwing-certbot-cert
                                                 wip-site-certbot-cert
                                                 jointhefreeworld-certbot-cert)))))
