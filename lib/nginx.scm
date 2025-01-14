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

(define-module (wolk-jjba nginx)
  #:use-module (gnu)
  #:use-module (guix))

(use-package-modules package-management)
(use-service-modules web)

(define-public wolk-jjba-base-nginx-conf
  (nginx-server-configuration (listen '("80"))
                              (server-name '("jointhefreeworld.org"
                                             "www.jointhefreeworld.org"
                                             "casadelcata.es"
                                             "www.casadelcata.es"
                                             "carvoeirowaterfun.com"
                                             "www.carvoeirowaterfun.com"
                                             "byggsteg.jointhefreeworld.org"
                                             "www.byggsteg.jointhefreeworld.org"
                                             "wikimusic.jointhefreeworld.org"
                                             "www.wikimusic.jointhefreeworld.org"
                                             "api.wikimusic.jointhefreeworld.org"))
                              (root "/srv/http")
                              (locations `(,(nginx-location-configuration (uri
                                                                           "/.well-known")
                                                                          (body '
                                                                           ("root /srv/http;"))) ,
                                           (nginx-location-configuration (uri
                                                                          "/")
                                                                         (body '
                                                                          ("return 307 https://$host$request_uri;")))))
                              (raw-content '())))

(define-public wolk-jjba-jointhefreeworld-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("jointhefreeworld.org"
                                             "www.jointhefreeworld.org"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/jointhefreeworld.org/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/jointhefreeworld.org/privkey.pem")
                              (root "/srv/http/jointhefreeworld.org")))

(define-public wolk-jjba-carvoeirowaterfun-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("carvoeirowaterfun.com"
                                             "www.carvoeirowaterfun.com"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/carvoeirowaterfun.com/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/carvoeirowaterfun.com/privkey.pem")
                              (root "/srv/http/carvoeirowaterfun.com")))

(define-public wolk-jjba-casadelcata-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("casadelcata.es"
                                             "www.casadelcata.es"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/casadelcata.es/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/casadelcata.es/privkey.pem")
                              (root "/srv/http/casadelcata.es")))

(define-public wolk-jjba-byggsteg-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("byggsteg.jointhefreeworld.org"
                                             "www.byggsteg.jointhefreeworld.org"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/byggsteg.jointhefreeworld.org/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/byggsteg.jointhefreeworld.org/privkey.pem")
                              (root "/srv/http")
                              (locations (list (nginx-location-configuration (uri
                                                                              "/")
                                                                             (body '
                                                                              ("proxy_pass http://byggsteg-proxy;")))))))

(define-public wolk-jjba-wikimusic-ssr-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("wikimusic.jointhefreeworld.org"
                                             "www.wikimusic.jointhefreeworld.org"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/wikimusic.jointhefreeworld.org/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/wikimusic.jointhefreeworld.org/privkey.pem")
                              (root "/srv/http")
                              (locations (list (nginx-location-configuration (uri
                                                                              "/")
                                                                             (body '
                                                                              ("proxy_pass http://wikimusic-ssr-proxy;")))))))

(define-public wolk-jjba-wikimusic-api-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("api.wikimusic.jointhefreeworld.org"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/api.wikimusic.jointhefreeworld.org/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/api.wikimusic.jointhefreeworld.org/privkey.pem")
                              (root "/srv/http")
                              (locations (list (nginx-location-configuration (uri
                                                                              "/")
                                                                             (body '
                                                                              ("proxy_pass http://wikimusic-api-proxy;")))))))

(define-public wolk-jjba-nginx
  (service nginx-service-type
           (nginx-configuration (server-blocks (list wolk-jjba-base-nginx-conf
                                                wolk-jjba-jointhefreeworld-nginx-conf
                                                wolk-jjba-carvoeirowaterfun-nginx-conf
                                                wolk-jjba-casadelcata-nginx-conf
                                                wolk-jjba-byggsteg-nginx-conf
                                                wolk-jjba-wikimusic-api-nginx-conf
                                                wolk-jjba-wikimusic-ssr-nginx-conf))
                                (upstream-blocks (list (nginx-upstream-configuration
                                                        (name "byggsteg-proxy")
                                                        (servers (list
                                                                  "127.0.0.1:50002")))
                                                       (nginx-upstream-configuration
                                                        (name
                                                         "wikimusic-api-proxy")
                                                        (servers (list
                                                                  "127.0.0.1:50050")))
                                                       (nginx-upstream-configuration
                                                        (name
                                                         "wikimusic-ssr-proxy")
                                                        (servers (list
                                                                  "127.0.0.1:6923"))))))))
