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
                               byggsteg-nginx-conf
                               lucidplan-nginx-conf
                               torikomi-nginx-conf
                               wikimusic-nginx-conf
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

(define http-2-3-settings
  (list "http2 on;" "quic_retry on;" "quic_gso on;"
        "add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"))

(define ssl-settings
  (list "ssl_session_timeout 1d;" "ssl_session_cache shared:SSL:10m;"
        "ssl_session_tickets on;" "ssl_protocols TLSv1.2 TLSv1.3;"
        "ssl_prefer_server_ciphers off;" "ssl_early_data on;"
        "add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always;"))

(define security-settings
  (list "add_header X-Content-Type-Options \"nosniff\" always;"
        "add_header Content-Security-Policy \"frame-ancestors 'none';\" always;"))

(define* (make-reverse-proxied-service-conf #:key name
                                            upstream-name
                                            (listen '("443 ssl"
                                                      "443 quic"))
                                            (raw-content '())
                                            (domain ".jointhefreeworld.org")
                                            (root "/srv/http")
                                            (cert-dir "/etc/letsencrypt/live")
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
                          "limit_req zone=proxy_rate_limited burst=72 nodelay;"
                          "limit_req_status 429;")
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
                                (raw-content (append http-2-3-settings gzip
                                                     rate-limit ssl-settings
                                                     security-settings
                                                     (list "proxy_set_header Early-Data $ssl_early_data;")
                                                     raw-content)))))

(define* (make-static-site-conf #:key name
                                (listen '("443 ssl" "443 quic"))
                                (raw-content '())
                                (root "/srv/http")
                                (name-in-root-path? #t)
                                (cert-dir "/etc/letsencrypt/live")
                                (with-www? #t)
                                (with-rate-limit? #t)
                                (with-gzip? #t)
                                (with-listdir? #f)
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
                          "limit_req zone=static_rate_limited burst=72 nodelay;"
                          "limit_req_status 429;")
                         '()))
         (listdir (if with-listdir?
                      (list "autoindex on;")
                      '())))
    (nginx-server-configuration (listen listen)
                                (server-name server-name)
                                (ssl-certificate (format #f
                                                  "~a/~a/fullchain.pem"
                                                  cert-dir name))
                                (ssl-certificate-key (format #f
                                                      "~a/~a/privkey.pem"
                                                      cert-dir name))
                                (root (if name-in-root-path?
                                          (format #f "~a/~a" root name)
                                          (format #f "~a" root)))
                                (locations (if with-static-asset-cache?
                                               (append (list (static-assets-cache-location
                                                              #:proxy-pass #f))
                                                       locations) locations))
                                (raw-content (append http-2-3-settings
                                                     gzip
                                                     rate-limit
                                                     ssl-settings
                                                     security-settings
                                                     raw-content
                                                     listdir)))))

(define metrics-nginx-conf
  (nginx-server-configuration (listen '("81 default_server"
                                        "[::]:81 default_server"))
                              (root "/srv/http/jointhefreeworld.org")
                              (locations (list (nginx-location-configuration (uri
                                                                              "/")
                                                                             (body
                                                                              (list
                                                                               "try_files $uri $uri/ =404;")))
                                               (nginx-location-configuration (uri
                                                                              "/nginx_status")
                                                                             (body
                                                                              (list
                                                                               "stub_status;"
                                                                               "allow 127.0.0.1;"
                                                                               "deny all;")))))))

(define certbot-nginx-conf
  (nginx-server-configuration (listen '("80"))
                              (server-name '("jointhefreeworld.org"
                                             "www.jointhefreeworld.org"
                                             "pingwing.jointhefreeworld.org"
                                             "carvoeirowaterfun.com"
                                             "www.carvoeirowaterfun.com"
                                             "prometheus.jointhefreeworld.org"
                                             "www.prometheus.jointhefreeworld.org"
                                             "prometheus-exporter.jointhefreeworld.org"
                                             "www.prometheus-exporter.jointhefreeworld.org"
                                             "grafana.jointhefreeworld.org"
                                             "www.grafana.jointhefreeworld.org"
                                             "byggsteg.jointhefreeworld.org"
                                             "www.byggsteg.jointhefreeworld.org"
                                             "lucidplan.jointhefreeworld.org"
                                             "www.lucidplan.jointhefreeworld.org"
                                             "hygguile.jointhefreeworld.org"
                                             "www.hygguile.jointhefreeworld.org"
                                             "torikomi.jointhefreeworld.org"
                                             "www.torikomi.jointhefreeworld.org"
                                             "visus-aeternus.jointhefreeworld.org"
                                             "www.visus-aeternus.jointhefreeworld.org"
                                             "wikimusic.jointhefreeworld.org"
                                             "www.wikimusic.jointhefreeworld.org"
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

(define hygguile-nginx-conf
  (make-static-site-conf #:name "hygguile.jointhefreeworld.org"))

(define visus-aeternus-nginx-conf
  (make-static-site-conf #:name "visus-aeternus.jointhefreeworld.org"
                         #:root "/srv/torikomi"
                         #:name-in-root-path? #f
                         #:with-listdir? #t))

(define torikomi-nginx-conf
  (make-reverse-proxied-service-conf #:name 'torikomi
                                     #:upstream-name 'torikomi-proxy
                                     #:raw-content '("auth_basic \"Restricted\";"
                                                     "auth_basic_user_file /srv/.htpasswd;")))

(define byggsteg-nginx-conf
  (make-reverse-proxied-service-conf #:name 'byggsteg
                                     #:upstream-name 'byggsteg-proxy))

(define grafana-nginx-conf
  (make-reverse-proxied-service-conf #:name 'grafana
                                     #:upstream-name 'grafana-proxy))

(define prometheus-nginx-conf
  (make-reverse-proxied-service-conf #:name 'prometheus
                                     #:upstream-name 'prometheus-proxy
                                     #:raw-content '("auth_basic \"Restricted\";"
                                                     "auth_basic_user_file /srv/.htpasswd;")))

(define prometheus-exporter-nginx-conf
  (make-reverse-proxied-service-conf #:name 'prometheus-exporter
                                     #:upstream-name 'prometheus-exporter-proxy))

(define lucidplan-nginx-conf
  (make-reverse-proxied-service-conf #:name 'lucidplan
                                     #:upstream-name 'lucidplan-proxy))

(define wikimusic-nginx-conf
  (make-reverse-proxied-service-conf #:name 'wikimusic
                                     #:upstream-name 'wikimusic-proxy))

(define pingwing-nginx-conf
  (make-reverse-proxied-service-conf #:name 'pingwing
                                     #:upstream-name 'pingwing-proxy
                                     #:raw-content '("auth_basic \"Restricted\";"
                                                     "auth_basic_user_file /srv/.htpasswd;")))

(define wip-site-nginx-conf
  (make-static-site-conf #:name "wip-site.jointhefreeworld.org"))

(define nginx-upstreams
  (list (nginx-upstream-configuration (name "byggsteg-proxy")
                                      (servers (list "127.0.0.1:50002")))
        (nginx-upstream-configuration (name "lucidplan-proxy")
                                      (servers (list "127.0.0.1:50025")))
        (nginx-upstream-configuration (name "grafana-proxy")
                                      (servers (list "127.0.0.1:53000")))
        (nginx-upstream-configuration (name "prometheus-proxy")
                                      (servers (list "127.0.0.1:59090")))
        (nginx-upstream-configuration (name "prometheus-exporter-proxy")
                                      (servers (list "127.0.0.1:59000")))
        (nginx-upstream-configuration (name "pingwing-proxy")
                                      (servers (list "127.0.0.1:50077")))
        (nginx-upstream-configuration (name "torikomi-proxy")
                                      (servers (list "127.0.0.1:50027")))
        (nginx-upstream-configuration (name "wikimusic-proxy")
                                      (servers (list "127.0.0.1:50050")))))

(define* (nginx-capability #:key (minimal-conf #f))
  (let ((base-conf (list certbot-nginx-conf metrics-nginx-conf))
        (app-conf (if minimal-conf
                      '()
                      (list jointhefreeworld-nginx-conf
                            carvoeirowaterfun-nginx-conf
                            byggsteg-nginx-conf
                            hygguile-nginx-conf
                            lucidplan-nginx-conf
                            prometheus-nginx-conf
                            prometheus-exporter-nginx-conf
                            grafana-nginx-conf
                            visus-aeternus-nginx-conf
                            torikomi-nginx-conf
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
                                                               ;; size limit for requests
                                                               "client_max_body_size 20M;"
                                                               ;; rate limiting directives
                                                               "limit_req_zone $binary_remote_addr zone=proxy_rate_limited:16m rate=16r/s;"
                                                               "limit_req_zone $binary_remote_addr zone=static_rate_limited:16m rate=32r/s;")
                                                              "\n"))))))
