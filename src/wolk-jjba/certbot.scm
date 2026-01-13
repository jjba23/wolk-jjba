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
                               wip-site-certbot-cert
                               oculuslambda-certbot-cert))

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

(define grafana-certbot-cert
  (make-site-cert #:domain "grafana.jointhefreeworld.org"))

(define wikimusic-certbot-cert
  (make-site-cert #:domain "wikimusic.jointhefreeworld.org"))

(define oculuslambda-certbot-cert
  (make-site-cert #:domain "oculuslambda.jointhefreeworld.org"
                  #:with-www? #f))

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
                                                 wikimusic-certbot-cert
                                                 oculuslambda-certbot-cert
                                                 torikomi-certbot-cert
                                                 visus-aeternus-certbot-cert
                                                 pingwing-certbot-cert
                                                 wip-site-certbot-cert
                                                 jointhefreeworld-certbot-cert)))))

