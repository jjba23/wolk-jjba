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

;; Commentary:
;;
;; The nginx capability: static sites, reverse proxies and the
;; certificates' HTTP-01 vhost.
;;
;; Two helpers build almost every server block:
;;
;;   - make-static-site-conf serves files from /srv/http/<name>;
;;   - make-reverse-proxied-service-conf proxies to an upstream.
;;
;; Both apply the same performance and security baseline:
;;
;;   - HTTP/2 + HTTP/3, gzip, a two-day static-asset cache, upstream
;;     keepalive and a shared TLS session cache;
;;   - HSTS, nosniff, DENY framing, a minimal CSP, Referrer-Policy and
;;     Permissions-Policy;
;;   - dotfile denial, per-IP connection and request limits, and
;;     request-body caps;
;;   - proxy headers that preserve Host, client IP, scheme, WebSocket
;;     upgrades and the TLS Early-Data flag.
;;
;; nginx-capability adds the global worker, timeout, file-cache, gzip,
;; rate-limit and proxy defaults, and keeps the ACME/metrics vhosts
;; separate from the application vhosts.  With #:minimal-conf #t only
;; the ACME and metrics vhosts are emitted, which is what a new machine
;; needs on its first reconfigure (the certificates do not exist yet).
;;
;; The nginx binary must be built with HTTP/3 support for the
;; "listen ... quic" directives; the Guix channel pinned in
;; channels.scm provides nginx 1.31.1 with --with-http_v3_module.
;;
;; Code:

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
                               radio-stream-locations
                               make-reverse-proxied-service-conf
                               make-static-site-conf))

(use-package-modules package-management)
(use-service-modules web)

(define http-2-3-settings
  (list "http2 on;" "quic_retry on;" "quic_gso on;"
        "add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"))

(define ssl-settings
  (list "ssl_session_timeout 1d;"
   "ssl_session_cache shared:SSL:10m;"
   "ssl_session_tickets on;"
   "ssl_protocols TLSv1.2 TLSv1.3;"
   "ssl_prefer_server_ciphers off;"
   "ssl_ecdh_curve X25519:prime256v1:secp384r1;"
   "ssl_early_data on;"))

(define security-settings
  (list "add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always;"
   "add_header X-Content-Type-Options \"nosniff\" always;"
   "add_header X-Frame-Options \"DENY\" always;"
   "add_header X-XSS-Protection \"0\" always;"
   "add_header Referrer-Policy \"strict-origin-when-cross-origin\" always;"
   "add_header Permissions-Policy \"accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()\" always;"
   "add_header Content-Security-Policy \"frame-ancestors 'none';\" always;"))

;; nginx writes its access log in logfmt, so Alloy, Loki and the
;; "Network & HTTP" dashboard can parse it with `| logfmt` and `unwrap`
;; the timing fields.  A single key=value line beats nginx's default
;; combined format for machine use: request time, upstream connect /
;; header / response time, the upstream address and the cache status
;; were not logged at all before, so latencies could not be measured.
;;
;; Values that may contain spaces (the path, the user agent) are quoted;
;; `escape=default` escapes quotes and control characters inside them.
;; `ref` is deliberately absent: the referer is the least useful field
;; and costs bytes on every line.
(define access-log-format
  (string-append
   "\"ts=$time_iso8601 host=$host remote=$remote_addr "
   "method=$request_method path=\\\"$uri\\\" proto=$server_protocol "
   "status=$status bytes=$body_bytes_sent req_bytes=$request_length "
   "duration=$request_time "
   "uct=\\\"$upstream_connect_time\\\" uht=\\\"$upstream_header_time\\\" "
   "urt=\\\"$upstream_response_time\\\" upstream=\\\"$upstream_addr\\\" "
   "cache=\\\"$upstream_cache_status\\\" "
   "ua=\\\"$http_user_agent\\\"\""))

(define gzip-settings
  (list "gzip on;"
   "gzip_static on;"
   "gzip_vary on;"
   "gzip_comp_level 5;"
   "gzip_min_length 512;"
   "gzip_proxied no-cache no-store private expired auth;"
   "gzip_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml application/manifest+json application/wasm image/svg+xml;"))

(define dotfile-location
  (nginx-location-configuration
   (uri "~ /\\.(?!well-known)")
   (body '("deny all;"))))

;; What every proxied location tells the upstream about the request.  These
;; belong to the server block, not to `location /': a location that sets no
;; `proxy_set_header' inherits the whole set, but one that sets its own
;; replaces it outright -- and a location with neither sends nginx's default
;; `Host: <upstream block name>'.
;;
;; That default is not harmless.  The static-asset location below matched
;; `*.js', `*.css' and `*.svg' with no headers of its own, so Grafana received
;; `Host: grafana-proxy' for every plugin module; Grafana builds redirect URLs
;; from the Host header and its `enforce_domain' setting redirected those
;; requests to https://grafana.jointhefreeworld.org/... .  The browser then
;; re-requested the same `.js' path, which matched the same location, which
;; sent the same Host: a redirect loop (ERR_TOO_MANY_REDIRECTS), so the
;; datasource plugins never loaded and every dashboard panel reported
;; "Datasource not found".
;;
;; Declared once and emitted at server level, so both locations -- and any
;; location added later -- speak to the upstream the same way.
(define reverse-proxy-headers
  (list "proxy_http_version 1.1;"
        "proxy_set_header Host $host;"
        "proxy_set_header X-Real-IP $remote_addr;"
        "proxy_set_header X-Forwarded-For $remote_addr;"
        "proxy_set_header X-Forwarded-Proto $scheme;"
        "proxy_set_header X-Forwarded-Host $host;"
        "proxy_set_header X-Forwarded-Port $server_port;"
        "proxy_set_header Upgrade $http_upgrade;"
        "proxy_set_header Connection $connection_upgrade;"
        "proxy_set_header Early-Data $ssl_early_data;"))

;; This location must not declare `proxy_set_header' of its own: it inherits
;; `reverse-proxy-headers' from the server block, which is what keeps the Host
;; header correct for a proxied asset.
(define* (static-assets-cache-location #:key (proxy-pass #f) (cors? #f))
  (nginx-location-configuration
   (uri "~* \\.(css|m?js|cjs|json|wasm|map|webmanifest|xml|txt|svg|jpe?g|png|gif|ico|cur|webp|avif|heic|heif|woff2?|ttf|otf|eot|mp4|webm|ogv|mp3|ogg|wav|flac|m4a|aac|pdf|zip|gz)$")
   (body (append
          (list "access_log off;"
                "log_not_found off;"
                ;; Static files are the one kind of request a browser
                ;; makes dozens of at once (a single page load opens
                ;; 30-60 of them), so they get the static bucket even in
                ;; an administrative vhost.  A `limit_req' in a location
                ;; replaces the one inherited from the server block
                ;; instead of adding to it, which is exactly what is
                ;; wanted here: the strict admin bucket then applies to
                ;; the application's own endpoints, where the work is,
                ;; and a Grafana page still renders on the first try.
                "limit_req zone=static_rate_limited burst=200 nodelay;"
                "limit_req_status 429;"
                "add_header Cache-Control \"public, max-age=172800, must-revalidate\" always;")
          (if cors?
              (list "add_header Access-Control-Allow-Origin * always;")
              '())
          security-settings
          (list "add_header Alt-Svc 'h3=\":443\"; ma=86400' always;")
          (if proxy-pass (list proxy-pass) '())))))

(define* (make-reverse-proxied-service-conf #:key name
                                            upstream-name
                                            (listen '("443 ssl" "443 quic"))
                                            (raw-content '())
                                            (domain ".jointhefreeworld.org")
                                            (root "/srv/http")
                                            (cert-dir "/etc/letsencrypt/live")
                                            (with-www? #t)
                                            (with-rate-limit? #t)
                                            (with-admin-lockdown? #f)
                                            (with-static-asset-cache? #t)
                                            (with-cors? #f)
                                            (with-gzip? #t))
  (let* ((proxy-locations
          (list (nginx-location-configuration
                 (uri "/")
                 ;; Only the pass and the timeouts: the request headers are
                 ;; server-level (see `reverse-proxy-headers') so that a
                 ;; location without a set of its own inherits them.
                 (body (list (format #f "proxy_pass http://~a;" upstream-name)
                             "proxy_connect_timeout 10s;"
                             "proxy_send_timeout 60s;"
                             "proxy_read_timeout 60s;"
                             "proxy_buffering on;")))))
         (server-name (append (list (format #f "~a~a" name domain))
                              (if with-www?
                                  (list (format #f "www.~a~a" name domain))
                                  '())))
         (gzip-off (if with-gzip? '() (list "gzip off;")))
         ;; An administrative vhost -- Grafana, Prometheus, the node
         ;; exporter -- is a single-user site behind the internet: one
         ;; browser, a handful of API calls, and no reason to hold many
         ;; connections.  Application vhosts keep the looser limits,
         ;; because a page of assets or an API client is legitimately
         ;; bursty.  nginx answers 429 before the request reaches the Go
         ;; process, so a flood costs a dropped connection rather than a
         ;; dashboard query.
         (limit-conn (if with-admin-lockdown?
                         (list "limit_conn conn_per_ip 10;"
                               "limit_conn_status 429;")
                         (list "limit_conn conn_per_ip 50;"
                               "limit_conn_status 429;")))
         (rate-limit (cond (with-admin-lockdown?
                            (list "limit_req zone=admin_rate_limited burst=60 nodelay;"
                                  "limit_req_status 429;"))
                           (with-rate-limit?
                            (list
                             "limit_req zone=proxy_rate_limited burst=200 nodelay;"
                             "limit_req_status 429;"))
                           (else '())))
         ;; An admin vhost accepts form posts and nothing bulky.
         (body-size (if with-admin-lockdown?
                        (list "client_max_body_size 2m;")
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
                                (locations (append
                                            (list dotfile-location)
                                            (if with-static-asset-cache?
                                                (list (static-assets-cache-location
                                                       #:proxy-pass (format
                                                                     #f
                                                                     "proxy_pass http://~a;"
                                                                     upstream-name)
                                                       #:cors? with-cors?))
                                                '())
                                            proxy-locations))
                                (raw-content (append http-2-3-settings
                                                     body-size
                                                     limit-conn
                                                     gzip-off
                                                     rate-limit
                                                     ssl-settings
                                                     security-settings
                                                     reverse-proxy-headers
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
                                (with-cors? #t)
                                (with-static-asset-cache? #t)
                                (locations '()))
  (let* ((server-name (append (list name)
                              (if with-www?
                                  (list (format #f "www.~a" name))
                                  '())))
         (gzip-off (if with-gzip? '() (list "gzip off;")))
         (limit-conn (list "limit_conn conn_per_ip 50;"
                           "limit_conn_status 429;"))
         (body-size (list "client_max_body_size 1m;"))
         (rate-limit (if with-rate-limit?
                         (list
                          "limit_req zone=static_rate_limited burst=200 nodelay;"
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
                                (locations (append
                                            (list dotfile-location)
                                            (if with-static-asset-cache?
                                                (list (static-assets-cache-location
                                                       #:proxy-pass #f
                                                       #:cors? with-cors?))
                                                '())
                                            locations))
                                (raw-content (append http-2-3-settings
                                                     body-size
                                                     limit-conn
                                                     gzip-off
                                                     rate-limit
                                                     ssl-settings
                                                     security-settings
                                                     raw-content
                                                     listdir)))))

;; Icecast on 6690 for anyone who has the direct URL, and nginx in front
;; of it on https://jointhefreeworld.org/radio/ for everything else.
;;
;; Four details make a live stream work behind a proxy, and getting any of
;; them wrong is a stutter rather than an error page:
;;
;;   - proxy_buffering off: nginx must not hold audio back to build a
;;     buffer.  With buffering on, a listener hears nothing until nginx
;;     has enough to flush, and every seek/reconnect restarts that
;;     latency;
;;   - a long proxy_read_timeout: an idle timeout of 60s kills a
;;     connection that is fine, because a stream is one request that
;;     never ends;
;;   - `location ^~`: the static-asset regex location matches
;;     `*.mp3' and would otherwise serve the request from disk (404)
;;     instead of proxying it.  `^~' takes precedence over every regex
;;     location;
;;   - the security headers are repeated, because a location that sets
;;     its own add_header inherits none from the server block.
(define* (radio-stream-locations #:key (upstream "radio-icecast"))
  (list
   (nginx-location-configuration
    (uri "^~ /radio/")
    (body (append
           (list (format #f "proxy_pass http://~a/;" upstream)
                 "proxy_http_version 1.1;"
                 "proxy_set_header Host $host;"
                 "proxy_set_header X-Real-IP $remote_addr;"
                 "proxy_set_header X-Forwarded-For $remote_addr;"
                 "proxy_set_header X-Forwarded-Proto $scheme;"
                 "proxy_set_header Connection \"\";"
                 "proxy_buffering off;"
                 "proxy_request_buffering off;"
                 "proxy_connect_timeout 10s;"
                 "proxy_send_timeout 3600s;"
                 "proxy_read_timeout 3600s;"
                 "proxy_ignore_client_abort on;"
                 "gzip off;"
                 "add_header Cache-Control \"no-store\" always;"
                 "add_header Access-Control-Allow-Origin \"*\" always;"
                 "add_header Access-Control-Allow-Methods \"GET, HEAD, OPTIONS\" always;"
                 "add_header Access-Control-Expose-Headers \"Content-Type, Content-Length, Accept-Ranges\" always;")
           security-settings
           (list "add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"))))))

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
                                             "symbanta.jointhefreeworld.org"
                                             "www.symbanta.jointhefreeworld.org"
                                             "api.symbanta.jointhefreeworld.org"
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
                                                                               "return 301 https://$host$request_uri;")))))
                              ;; Port 80 is the one vhost nobody has to
                              ;; authenticate for, and it exists only to
                              ;; redirect and to answer HTTP-01
                              ;; challenges.  It therefore gets the same
                              ;; abuse limits as a static site: without
                              ;; them a redirect loop ("GET / HTTP/1.1"
                              ;; as fast as the client can open sockets)
                              ;; is free CPU for the attacker.
                              (raw-content (list "limit_conn conn_per_ip 20;"
                                                 "limit_conn_status 429;"
                                                 "limit_req zone=static_rate_limited burst=50 nodelay;"
                                                 "limit_req_status 429;"))))

(define jointhefreeworld-nginx-conf
  (make-static-site-conf #:name "jointhefreeworld.org"
                         #:locations (append
                                      (radio-stream-locations)
                                      (list (nginx-location-configuration (uri
                                                                          "/articles/")
                                                                         (body
                                                                          (list
                                                                           "rewrite ^/articles/(.*)$ /blog/articles/$1 last;")))))))

(define symbanta-nginx-conf
  (make-static-site-conf #:name "symbanta.jointhefreeworld.org"
                         #:locations (list (nginx-location-configuration (uri
                                                                          "/")
                                                                         (body
                                                                          (list
                                                                           "try_files $uri $uri/ /index.html;"))))
                         #:root "/srv/symbanta.jointhefreeworld.org"
                         #:name-in-root-path? #f))

(define symbanta-api-nginx-conf
  ;; An API host has no www alias: the certificate requested for it in
  ;; (wolk-jjba certbot) covers the bare name only, and a www name here
  ;; would be a vhost with no certificate behind it.
  (make-reverse-proxied-service-conf #:name "api.symbanta"
                                     #:upstream-name 'symbanta-api-proxy
                                     #:with-www? #f))

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

;; The three administrative vhosts share the same pressure valves: the
;; strict `admin_rate_limited' bucket (10 r/s, burst 60), a
;; ten-connection-per-address cap and a 2 MiB body cap.  Prometheus and
;; the node exporter sit behind HTTP basic auth as well: neither has an
;; account system of its own, and the exporter publishes uptime, disk,
;; interface and process numbers -- a map of the machine for anyone who
;; asks.
;;
;; Grafana is deliberately *not* behind that lock.  It has its own login,
;; and the second authentication layer in front of it broke the
;; application: a browser answers the challenge for a navigation, but the
;; module imports a single-page app loads on demand came back 401, so
;; every plugin module failed to load and the UI reported "Could not load
;; plugin" and "Datasource not found" while Grafana's own log showed no
;; such request at all.  The forwarded `Authorization' header was also
;; read by Grafana as a login attempt, filling the log with
;; `identity.not-found' for accounts that exist in /srv/.htpasswd and
;; nowhere else.  The rate and connection limits above are what protects
;; the vhost from a flood; who may see a dashboard is Grafana's own
;; question.
(define admin-basic-auth
  '("auth_basic \"Restricted\";"
    "auth_basic_user_file /srv/.htpasswd;"))

(define grafana-nginx-conf
  (make-reverse-proxied-service-conf #:name 'grafana
                                     #:upstream-name 'grafana-proxy
                                     #:with-admin-lockdown? #t))

(define prometheus-nginx-conf
  (make-reverse-proxied-service-conf #:name 'prometheus
                                     #:upstream-name 'prometheus-proxy
                                     #:with-admin-lockdown? #t
                                     #:raw-content admin-basic-auth))

(define prometheus-exporter-nginx-conf
  (make-reverse-proxied-service-conf #:name 'prometheus-exporter
                                     #:upstream-name 'prometheus-exporter-proxy
                                     #:with-admin-lockdown? #t
                                     #:raw-content admin-basic-auth))

(define lucidplan-nginx-conf
  (make-reverse-proxied-service-conf #:name 'lucidplan
                                     #:upstream-name 'lucidplan-proxy))

(define wikimusic-nginx-conf
  (make-reverse-proxied-service-conf #:name 'wikimusic
                                     #:upstream-name 'wikimusic-proxy))

(define pingwing-nginx-conf
  ;; The certificate for pingwing is requested for the bare name only, so
  ;; the vhost answers for the bare name only; a www alias would be served
  ;; with a certificate that does not cover it.
  (make-reverse-proxied-service-conf #:name 'pingwing
                                     #:upstream-name 'pingwing-proxy
                                     #:with-www? #f
                                     #:raw-content '("auth_basic \"Restricted\";"
                                                     "auth_basic_user_file /srv/.htpasswd;")))

(define wip-site-nginx-conf
  (make-static-site-conf #:name "wip-site.jointhefreeworld.org"))

(define* (make-upstream name server)
  (nginx-upstream-configuration
   (name name)
   (servers (list server))
   (extra-content '("keepalive 64;" "keepalive_timeout 60s;"))))

(define nginx-upstreams
  (list ;; The radio is a long-lived response, so its upstream gets no
        ;; keepalive pool: the connection is never idle-reusable, and a
        ;; pooled one would only add a stale-socket risk to a stream.
        (nginx-upstream-configuration (name "radio-icecast")
                                      (servers '("127.0.0.1:6690")))
        (make-upstream "byggsteg-proxy" "127.0.0.1:50002")
        (make-upstream "lucidplan-proxy" "127.0.0.1:50025")
        (make-upstream "symbanta-api-proxy" "127.0.0.1:8080")
        (make-upstream "grafana-proxy" "127.0.0.1:53000")
        (make-upstream "prometheus-proxy" "127.0.0.1:59090")
        (make-upstream "prometheus-exporter-proxy" "127.0.0.1:9100")
        (make-upstream "pingwing-proxy" "127.0.0.1:50077")
        (make-upstream "torikomi-proxy" "127.0.0.1:50027")
        (make-upstream "wikimusic-proxy" "127.0.0.1:50050")))

(define* (nginx-capability #:key (minimal-conf #f))
  (let ((base-conf (list certbot-nginx-conf metrics-nginx-conf))
        (app-conf (if minimal-conf
                      '()
                      (list jointhefreeworld-nginx-conf
                            symbanta-nginx-conf
                            symbanta-api-nginx-conf
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
             (nginx-configuration
              (server-blocks (append base-conf app-conf))
              (upstream-blocks nginx-upstreams)
              ;; The logfmt access log described above; see the
              ;; "Network & HTTP" dashboard for the queries that read it.
              (log-format 'wolk)
              (log-formats
               (list (nginx-log-format-configuration
                      (name 'wolk)
                      (format access-log-format))))
              (server-names-hash-bucket-size 64)
              (global-directives
               '((worker_processes . auto)
                 (worker_rlimit_nofile . 16384)
                 (pcre_jit . on)
                 (events . ((worker_connections . 8192)
                            (multi_accept . on)))))
              (extra-content
               (append
                (list
                 ;; --- performance -------------------------------------
                 ;; copy data between file descriptors, faster than read+write
                 "sendfile on;"
                 ;; send headers in one piece
                 "tcp_nopush on;"
                 ;; don't buffer small writes
                 "tcp_nodelay on;"
                 ;; keep connections alive between requests
                 "keepalive_timeout 65s;"
                 "keepalive_requests 2000;"
                 ;; free idle connections quickly
                 "reset_timedout_connection on;"
                 ;; keep slow or stuck clients from occupying workers
                 "client_body_timeout 30s;"
                 "client_header_timeout 30s;"
                 "send_timeout 30s;"
                 "client_body_buffer_size 256k;"
                 ;; global request cap; static vhosts override this to 1m
                 "client_max_body_size 20M;"
                 "types_hash_max_size 2048;"
                 "server_names_hash_max_size 512;"
                 ;; cache static-file metadata
                 "open_file_cache max=20000 inactive=30s;"
                 "open_file_cache_valid 60s;"
                 "open_file_cache_min_uses 2;"
                 "open_file_cache_errors on;"
                 ;; --- proxy defaults ----------------------------------
                 "proxy_http_version 1.1;"
                 "proxy_connect_timeout 10s;"
                 "proxy_send_timeout 60s;"
                 "proxy_read_timeout 60s;"
                 "proxy_buffer_size 16k;"
                 "proxy_buffers 16 16k;"
                 "proxy_busy_buffers_size 64k;"
                 "proxy_headers_hash_max_size 1024;"
                 "proxy_headers_hash_bucket_size 128;"
                 ;; do not leak upstream implementation details
                 "proxy_hide_header X-Powered-By;"
                 "proxy_hide_header X-AspNet-Version;"
                 ;; preserve WebSocket upgrades while keeping upstream
                 ;; keepalive for ordinary requests
                 "map $http_upgrade $connection_upgrade {"
                 "    default upgrade;"
                 "    ''      '';"
                 "}"
                 ;; --- security ----------------------------------------
                 ;; hide the nginx version in Server and error pages
                 "server_tokens off;"
                 ;; --- abuse limits ------------------------------------
                 "limit_conn_zone $binary_remote_addr zone=conn_per_ip:20m;"
                 "limit_req_zone $binary_remote_addr zone=proxy_rate_limited:32m rate=50r/s;"
                 "limit_req_zone $binary_remote_addr zone=static_rate_limited:32m rate=100r/s;"
                 ;; One bucket for every administrative vhost (Grafana,
                 ;; Prometheus, the node exporter): ten requests a second
                 ;; with a burst of sixty is more than a dashboard UI
                 ;; makes once its static assets are out of the way (they
                 ;; use the static bucket above), and two orders of
                 ;; magnitude less than a password guesser or a scraper
                 ;; needs.  The zone is shared by all three vhosts, so this
                 ;; is one budget per client address across the whole admin
                 ;; surface.  Static files are exempt on purpose: a Grafana
                 ;; page load opens dozens of requests at once and a bucket
                 ;; this small would 429 the dashboard it is protecting.
                 "limit_req_zone $binary_remote_addr zone=admin_rate_limited:16m rate=10r/s;"
                 "limit_req_log_level warn;"
                 "limit_conn_log_level warn;")
                gzip-settings))))))
