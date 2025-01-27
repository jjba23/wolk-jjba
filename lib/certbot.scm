;;;; wolk-jjba

;; Copyright (C) 2024 Josep Jesus Bigorra Algaba

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
  #:use-module (guix))

(use-service-modules certbot)

(define-public %nginx-deploy-hook
  (program-file "nginx-deploy-hook"
                #~(let ((pid (call-with-input-file "/var/run/nginx/pid"
                               read)))
                    (kill pid SIGHUP))))

(define-public wolk-jjba-jointhefreeworld-certbot-cert
  (certificate-configuration (domains '("jointhefreeworld.org"
                                        "www.jointhefreeworld.org"))
                             (deploy-hook %nginx-deploy-hook)))

(define-public wolk-jjba-carvoeirowaterfun-certbot-cert
  (certificate-configuration (domains '("carvoeirowaterfun.com"
                                        "www.carvoeirowaterfun.com"))
                             (deploy-hook %nginx-deploy-hook)))

(define-public wolk-jjba-casadelcata-certbot-cert
  (certificate-configuration (domains '("casadelcata.es" "www.casadelcata.es"))
                             (deploy-hook %nginx-deploy-hook)))

(define-public wolk-jjba-byggsteg-certbot-cert
  (certificate-configuration (domains '("byggsteg.jointhefreeworld.org"
                                        "www.byggsteg.jointhefreeworld.org"))
                             (deploy-hook %nginx-deploy-hook)))

(define-public wolk-jjba-lucidplan-certbot-cert
  (certificate-configuration (domains '("lucidplan.jointhefreeworld.org"
                                        "www.lucidplan.jointhefreeworld.org"))
                             (deploy-hook %nginx-deploy-hook)))


(define-public wolk-jjba-wikimusic-ssr-certbot-cert
  (certificate-configuration (domains '("wikimusic.jointhefreeworld.org"
                                        "www.wikimusic.jointhefreeworld.org"))
                             (deploy-hook %nginx-deploy-hook)))

(define-public wolk-jjba-wikimusic-api-certbot-cert
  (certificate-configuration (domains '("api.wikimusic.jointhefreeworld.org"))
                             (deploy-hook %nginx-deploy-hook)))

;; You may want to use a staging ACME server when testing.
;; (define-public %certbot-server
;;   "https://acme-staging-v02.api.letsencrypt.org/directory")

(define-public wolk-jjba-certbot
  (service certbot-service-type
           (certbot-configuration (email "jjbigorra@gmail.com")
                                  (webroot "/srv/http")
                                  (certificates (list
                                                 wolk-jjba-casadelcata-certbot-cert
                                                 wolk-jjba-carvoeirowaterfun-certbot-cert
                                                 wolk-jjba-wikimusic-api-certbot-cert
                                                 wolk-jjba-byggsteg-certbot-cert
                                                 wolk-jjba-lucidplan-certbot-cert
                                                 wolk-jjba-wikimusic-ssr-certbot-cert
                                                 wolk-jjba-jointhefreeworld-certbot-cert)))))
