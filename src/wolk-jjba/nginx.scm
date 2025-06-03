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

(define-module (wolk-jjba nginx)
  #:use-module (gnu)
  #:use-module (guix)
  #:export (certbot-nginx-conf nginx-capability
                               carvoeirowaterfun-nginx-conf
                               hygguile-nginx-conf
                               casadelcata-nginx-conf
                               byggsteg-nginx-conf
                               lucidplan-nginx-conf
                               wikimusic-nginx-conf
                               oculuslambda-nginx-conf
                               jointhefreeworld-nginx-conf
                               make-reverse-proxied-service-conf))

(use-package-modules package-management)
(use-service-modules web)

(define* (make-reverse-proxied-service-conf #:key name
                                            upstream-name
                                            (listen '("443 ssl"))
                                            (raw-content '("http2 on;"))
                                            (domain ".jointhefreeworld.org")
                                            (root "/srv/http")
                                            (cert-dir "/etc/letsencrypt/live")
                                            (with-www? #t))
  (let* ((proxy-locations (list (nginx-location-configuration (uri "/")
                                                              (body (list (format
                                                                           #f
                                                                           "proxy_pass http://~a;"
                                                                           upstream-name)))))))
    (nginx-server-configuration (listen listen)
                                (server-name (append (list (format #f "~a~a"
                                                                   name domain))
                                                     (if with-www?
                                                         (list (format #f
                                                                "www.~a~a"
                                                                name domain))
                                                         '())))
                                (ssl-certificate (format #f
                                                  "~a/~a~a/fullchain.pem"
                                                  cert-dir name domain))
                                (ssl-certificate-key (format #f
                                                      "~a/~a~a/privkey.pem"
                                                      cert-dir name domain))
                                (root root)
                                (locations proxy-locations)
                                (raw-content raw-content))))

(define certbot-nginx-conf
  (nginx-server-configuration (listen '("80"))
                              (server-name '("jointhefreeworld.org"
                                             "www.jointhefreeworld.org"
                                             "casadelcata.es"
                                             "www.casadelcata.es"
                                             "oculuslambda.jointhefreeworld.org"
                                             "www.oculuslambda.jointhefreeworld.org"
                                             "carvoeirowaterfun.com"
                                             "www.carvoeirowaterfun.com"
                                             "byggsteg.jointhefreeworld.org"
                                             "www.byggsteg.jointhefreeworld.org"
                                             "lucidplan.jointhefreeworld.org"
                                             "www.lucidplan.jointhefreeworld.org"
                                             "hygguile.jointhefreeworld.org"
                                             "www.hygguile.jointhefreeworld.org"
                                             "wikimusic.jointhefreeworld.org"
                                             "www.wikimusic.jointhefreeworld.org"))
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

(define jointhefreeworld-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("jointhefreeworld.org"
                                             "www.jointhefreeworld.org"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/jointhefreeworld.org/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/jointhefreeworld.org/privkey.pem")
                              (root "/srv/http/jointhefreeworld.org")
                              (locations `(,(nginx-location-configuration (uri
                                                                           "/articles/")
                                                                          (body '
                                                                           ("rewrite ^/articles/(.*)$ /blog/articles/$1 last;")))))
                              (raw-content '("http2 on;"))))

(define carvoeirowaterfun-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("carvoeirowaterfun.com"
                                             "www.carvoeirowaterfun.com"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/carvoeirowaterfun.com/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/carvoeirowaterfun.com/privkey.pem")
                              (root "/srv/http/carvoeirowaterfun.com")
                              (raw-content '("http2 on;"))))

(define casadelcata-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("casadelcata.es"
                                             "www.casadelcata.es"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/casadelcata.es/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/casadelcata.es/privkey.pem")
                              (root "/srv/http/casadelcata.es")
                              (raw-content '("http2 on;"))))

(define hygguile-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("hygguile.jointhefreeworld.org"
                                             "www.hygguile.jointhefreeworld.org"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/hygguile.jointhefreeworld.org/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/hygguile.jointhefreeworld.org/privkey.pem")
                              (root "/srv/http/hygguile.jointhefreeworld.org")
                              (raw-content '("http2 on;"))))

(define byggsteg-nginx-conf
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
                                                                              ("proxy_pass http://byggsteg-proxy;")))))
                              (raw-content '("http2 on;"))))

(define lucidplan-nginx-conf
  (nginx-server-configuration (listen '("443 ssl"))
                              (server-name '("lucidplan.jointhefreeworld.org"
                                             "www.lucidplan.jointhefreeworld.org"))
                              (ssl-certificate
                               "/etc/letsencrypt/live/lucidplan.jointhefreeworld.org/fullchain.pem")
                              (ssl-certificate-key
                               "/etc/letsencrypt/live/lucidplan.jointhefreeworld.org/privkey.pem")
                              (root "/srv/http")
                              (locations (list (nginx-location-configuration (uri
                                                                              "/")
                                                                             (body '
                                                                              ("proxy_pass http://lucidplan-proxy;")))))
                              (raw-content '("http2 on;"))))

(define wikimusic-nginx-conf
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
                                                                              ("proxy_pass http://wikimusic-proxy;")))))
                              (raw-content '("http2 on;"))))

(define oculuslambda-nginx-conf
  (make-reverse-proxied-service-conf #:name 'oculuslambda
                                     #:upstream-name 'oculuslambda-proxy))

(define nginx-upstreams
  (list (nginx-upstream-configuration (name "byggsteg-proxy")
                                      (servers (list "127.0.0.1:50002")))
        (nginx-upstream-configuration (name "lucidplan-proxy")
                                      (servers (list "127.0.0.1:50025")))
        (nginx-upstream-configuration (name "oculuslambda-proxy")
                                      (servers (list "127.0.0.1:50009")))
        (nginx-upstream-configuration (name "wikimusic-proxy")
                                      (servers (list "127.0.0.1:50050")))))

(define* (nginx-capability #:key (minimal-conf #f))
  (let ((base-conf (list certbot-nginx-conf))
        (app-conf (if minimal-conf
                      '()
                      (list jointhefreeworld-nginx-conf
                            carvoeirowaterfun-nginx-conf
                            casadelcata-nginx-conf
                            byggsteg-nginx-conf
                            hygguile-nginx-conf
                            lucidplan-nginx-conf
                            oculuslambda-nginx-conf
                            wikimusic-nginx-conf))))
    (service nginx-service-type
             (nginx-configuration (server-blocks (append base-conf app-conf))
                                  (upstream-blocks nginx-upstreams)))))
