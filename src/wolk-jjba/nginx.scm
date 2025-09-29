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
                               make-reverse-proxied-service-conf
                               make-static-site-conf))

(use-package-modules package-management)
(use-service-modules web)

(define* (static-assets-cache-location #:key (proxy-pass #f))
  (nginx-location-configuration (uri
                                 "~* \\.(svg|jpg|jpeg|png|avif|webp|gif|ico|css|js|pdf)$")
                                (body (list "access_log off;"
                                       "add_header Cache-Control public;"
                                       "add_header Cache-Control must-revalidate;"
                                       "expires 2d;"
                                       (if (not proxy-pass) "" proxy-pass)))))

(define* (make-reverse-proxied-service-conf #:key name
                                            upstream-name
                                            (listen '("443 ssl"))
                                            (raw-content '())
                                            (domain ".jointhefreeworld.org")
                                            (root "/srv/http")
                                            (cert-dir "/etc/letsencrypt/live")
                                            (with-http2? #t)
                                            (with-www? #t)
                                            (with-rate-limit? #t)
                                            (with-static-asset-cache? #t)
                                            (with-gzip? #t))
  (let* ((proxy-locations (list (nginx-location-configuration (uri "/")
                                                              (body (list (format
                                                                           #f
                                                                           "proxy_pass http://~a;"
                                                                           upstream-name))))))
         (server-name (append (list (format #f "~a~a" name domain))
                              (if with-www?
                                  (list (format #f "www.~a~a" name domain))
                                  '())))
         (gzip (if with-gzip?
                   (list "gzip on;"
                    "gzip_types text/html text/plain application/xml text/css text/javascript application/json;"
                    "gzip_proxied no-cache no-store private expired auth;"
                    "gzip_min_length 512;")
                   '()))
         (rate-limit (if with-rate-limit?
                         (list
                          "limit_req zone=proxy_rate_limited burst=24 nodelay;"
                          "limit_req_status 429;")
                         '()))
         (ssl-cache (list "ssl_session_timeout 1d;"
                          "ssl_session_cache shared:SSL:50m;"
                          "ssl_session_tickets off;"))
         (http2 (if with-http2?
                    (list "http2 on;")
                    '())))
    (nginx-server-configuration (listen listen)
                                (server-name server-name)
                                (ssl-certificate (format #f
                                                  "~a/~a~a/fullchain.pem"
                                                  cert-dir name domain))
                                (ssl-certificate-key (format #f
                                                      "~a/~a~a/privkey.pem"
                                                      cert-dir name domain))
                                (root root)
                                (locations (if with-static-asset-cache?
                                               (append (list (static-assets-cache-location
                                                              #:proxy-pass (format
                                                                            #f
                                                                            "proxy_pass http://~a;"
                                                                            upstream-name)))
                                                       proxy-locations)
                                               proxy-locations))
                                (raw-content (append http2 gzip rate-limit
                                                     ssl-cache raw-content)))))

(define* (make-static-site-conf #:key name
                                (listen '("443 ssl"))
                                (raw-content '())
                                (root "/srv/http")
                                (cert-dir "/etc/letsencrypt/live")
                                (with-http2? #t)
                                (with-www? #t)
                                (with-rate-limit? #t)
                                (with-gzip? #t)
                                (with-static-asset-cache? #t)
                                (locations '()))
  (let* ((server-name (append (list name)
                              (if with-www?
                                  (list (format #f "www.~a" name))
                                  '())))
         (gzip (if with-gzip?
                   (list "gzip on;"
                    "gzip_types text/html text/plain application/xml text/css text/javascript application/json;"
                    "gzip_proxied no-cache no-store private expired auth;"
                    "gzip_min_length 512;")
                   '()))
         (rate-limit (if with-rate-limit?
                         (list
                          "limit_req zone=static_rate_limited burst=24 nodelay;"
                          "limit_req_status 429;")
                         '()))
         (ssl-cache (list "ssl_session_timeout 1d;"
                          "ssl_session_cache shared:SSL:50m;"
                          "ssl_session_tickets off;"))
         (http2 (if with-http2?
                    (list "http2 on;")
                    '())))
    (nginx-server-configuration (listen listen)
                                (server-name server-name)
                                (ssl-certificate (format #f
                                                  "~a/~a/fullchain.pem"
                                                  cert-dir name))
                                (ssl-certificate-key (format #f
                                                      "~a/~a/privkey.pem"
                                                      cert-dir name))
                                (root (format #f "~a/~a" root name))
                                (locations (if with-static-asset-cache?
                                               (append (list (static-assets-cache-location
                                                              #:proxy-pass #f))
                                                       locations) locations))
                                (raw-content (append http2 gzip rate-limit
                                                     ssl-cache raw-content)))))

(define certbot-nginx-conf
  (nginx-server-configuration (listen '("80"))
                              (server-name '("jointhefreeworld.org"
                                             "www.jointhefreeworld.org"
                                             "casadelcata.es"
                                             "www.casadelcata.es"
                                             "oculuslambda.jointhefreeworld.org"
                                             "www.oculuslambda.jointhefreeworld.org"
                                             "pingwing.jointhefreeworld.org"
                                             "carvoeirowaterfun.com"
                                             "www.carvoeirowaterfun.com"
                                             "byggsteg.jointhefreeworld.org"
                                             "www.byggsteg.jointhefreeworld.org"
                                             "lucidplan.jointhefreeworld.org"
                                             "www.lucidplan.jointhefreeworld.org"
                                             "hygguile.jointhefreeworld.org"
                                             "www.hygguile.jointhefreeworld.org"
                                             "wikimusic.jointhefreeworld.org"
                                             "www.wikimusic.jointhefreeworld.org"
                                             "rchuidkliniek.nl"
                                             "www.rchuidkliniek.nl"
                                             "rchuidkliniek.beta.jointhefreeworld.org"
                                             "www.rchuidkliniek.beta.jointhefreeworld.org"
                                             "wip-site.jointhefreeworld.org"
                                             "www.wip-site.jointhefreeworld.org"))
                              (root "/srv/http")
                              (locations (list (nginx-location-configuration (uri
                                                                              "/.well-known")
                                                                             (body
                                                                              (list
                                                                               "root /srv/http;")))
                                               (nginx-location-configuration (uri
                                                                              "/")
                                                                             (body
                                                                              (list
                                                                               "return 307 https://$host$request_uri;")))))
                              (raw-content '())))

(define jointhefreeworld-nginx-conf
  (make-static-site-conf #:name "jointhefreeworld.org"
                         #:locations (list (nginx-location-configuration (uri
                                                                          "/articles/")
                                                                         (body
                                                                          (list
                                                                           "rewrite ^/articles/(.*)$ /blog/articles/$1 last;"))))))

(define carvoeirowaterfun-nginx-conf
  (make-static-site-conf #:name "carvoeirowaterfun.com"))

(define casadelcata-nginx-conf
  (make-static-site-conf #:name "casadelcata.es"))

(define hygguile-nginx-conf
  (make-static-site-conf #:name "hygguile.jointhefreeworld.org"))

(define rc-huidkliniek-nginx-conf
  (make-static-site-conf #:name "rchuidkliniek.nl"))

(define rc-huidkliniek-beta-nginx-conf
  (make-static-site-conf #:name "rchuidkliniek.beta.jointhefreeworld.org"
                         #:raw-content '("auth_basic \"Restricted Area: RC Huidkliniek Beta\";"
                                         "auth_basic_user_file /etc/nginx/.htpasswd;")))

(define byggsteg-nginx-conf
  (make-reverse-proxied-service-conf #:name 'byggsteg
                                     #:upstream-name 'byggsteg-proxy))

(define lucidplan-nginx-conf
  (make-reverse-proxied-service-conf #:name 'lucidplan
                                     #:upstream-name 'lucidplan-proxy))

(define wikimusic-nginx-conf
  (make-reverse-proxied-service-conf #:name 'wikimusic
                                     #:upstream-name 'wikimusic-proxy))

(define oculuslambda-nginx-conf
  (make-reverse-proxied-service-conf #:name 'oculuslambda
                                     #:upstream-name 'oculuslambda-proxy))

(define pingwing-nginx-conf
  (make-reverse-proxied-service-conf #:name 'pingwing
                                     #:upstream-name 'pingwing-proxy
                                     #:raw-content '("auth_basic \"Restricted Area: PingWing\";"
                                                     "auth_basic_user_file /etc/nginx/.htpasswd;")))

(define wip-site-nginx-conf
  (make-static-site-conf #:name "wip-site.jointhefreeworld.org"))

(define nginx-upstreams
  (list (nginx-upstream-configuration (name "byggsteg-proxy")
                                      (servers (list "127.0.0.1:50002")))
        (nginx-upstream-configuration (name "lucidplan-proxy")
                                      (servers (list "127.0.0.1:50025")))
        (nginx-upstream-configuration (name "oculuslambda-proxy")
                                      (servers (list "127.0.0.1:50009")))
        (nginx-upstream-configuration (name "pingwing-proxy")
                                      (servers (list "127.0.0.1:50077")))
        (nginx-upstream-configuration (name "wikimusic-proxy")
                                      (servers (list "127.0.0.1:50050")))))

(define* (nginx-capability #:key (minimal-conf #f))
  (let ((base-conf (list certbot-nginx-conf))
        (app-conf (if minimal-conf
                      '()
                      (list jointhefreeworld-nginx-conf
                            carvoeirowaterfun-nginx-conf
                            rc-huidkliniek-nginx-conf
                            rc-huidkliniek-beta-nginx-conf
                            casadelcata-nginx-conf
                            byggsteg-nginx-conf
                            hygguile-nginx-conf
                            lucidplan-nginx-conf
                            oculuslambda-nginx-conf
                            pingwing-nginx-conf
                            wip-site-nginx-conf
                            wikimusic-nginx-conf))))
    (service nginx-service-type
             (nginx-configuration (server-blocks (append base-conf app-conf))
                                  (upstream-blocks nginx-upstreams)
                                  (extra-content (string-join (list
                                                               ;; copy data between file descriptors, faster than read+write
                                                               "sendfile on;"
                                                               ;; send headers in one piece, it is better than sending them one by one
                                                               "tcp_nopush on;"
                                                               ;; don't buffer data sent, good for small data bursts in real time
                                                               "tcp_nodelay on;"
                                                               ;; read timeout for the request body from client
                                                               "client_body_timeout 3m;"
                                                               ;; how long to wait for the client to send a request header
                                                               "client_header_timeout 3m;"
                                                               ;; rate limiting directives
                                                               "limit_req_zone $binary_remote_addr zone=proxy_rate_limited:16m rate=16r/s;"
                                                               "limit_req_zone $binary_remote_addr zone=static_rate_limited:16m rate=32r/s;")
                                                              "\n"))))))
