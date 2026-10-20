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

;;; Commentary:
;;
;; Unit tests for (wolk-jjba nginx).  A server block is a record, so the
;; tests read the records rather than a rendered file: that catches the
;; things nginx would only complain about at reload time -- a vhost
;; proxying to an upstream nobody declared, a certificate path that does
;; not follow the vhost's name, a missing security header -- and it also
;; checks the two knobs that matter operationally, `minimal-conf' and the
;; rate limits.

;;; Code:

(define-module (veritas unit nginx-spec)
  #:use-module (veritas veritas)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (gnu services)
  #:use-module (gnu services web)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba nginx)
  #:export (spec))

(define (any-string-matches? strings pattern)
  "Return #t when any of STRINGS matches the regexp PATTERN."
  (let ((rx (make-regexp pattern)))
    (any (lambda (s) (and (string? s) (regexp-exec rx s) #t)) strings)))

(define (strings-of tree)
  "Flatten TREE into the list of strings it contains."
  (cond
    ((null? tree) '())
    ((string? tree) (list tree))
    ((pair? tree) (append (strings-of (car tree)) (strings-of (cdr tree))))
    ((vector? tree) (strings-of (vector->list tree)))
    (else '())))

(define (proxy-targets block)
  "Return the upstream names the server BLOCK proxies to."
  (let ((rx (make-regexp "^proxy_pass http://([^;]+);$")))
    (filter-map (lambda (line)
                  (let ((m (and (string? line) (regexp-exec rx line))))
                    (and m (match:substring m 1))))
                (append (location-strings block)
                        (strings-of
                         (nginx-server-configuration-raw-content block))))))

(define (server-block-by-name blocks name)
  "Return the first application block in BLOCKS whose server-name holds NAME.

The certificate and metrics blocks are prepended to the list and answer for
every domain, so they are skipped: the question is which block *serves* the
name over TLS."
  (find (lambda (block)
          (and (member name (nginx-server-configuration-server-name block))
               (member "443 ssl"
                       (nginx-server-configuration-listen block))))
        blocks))

(define (location-strings block)
  "Return every directive in the locations of BLOCK."
  (append-map nginx-location-configuration-body
              (nginx-server-configuration-locations block)))

(define full-capability (service-value (nginx-capability)))
(define minimal-capability (service-value (nginx-capability #:minimal-conf #t)))

(define full-blocks (nginx-configuration-server-blocks full-capability))
(define minimal-blocks (nginx-configuration-server-blocks minimal-capability))
(define upstreams (nginx-configuration-upstream-blocks full-capability))

(define upstream-names
  (map nginx-upstream-configuration-name upstreams))

(define jointhefreeworld-block
  (server-block-by-name full-blocks "jointhefreeworld.org"))
(define byggsteg-block (server-block-by-name full-blocks "byggsteg.jointhefreeworld.org"))
(define torikomi-block
  (server-block-by-name full-blocks "torikomi.jointhefreeworld.org"))
(define symbanta-block
  (server-block-by-name full-blocks "symbanta.jointhefreeworld.org"))

(define (static-site-sample)
  "A small static vhost used to test the helper's knobs."
  (make-static-site-conf #:name "example.test"
                         #:with-cors? #f
                         #:with-rate-limit? #f
                         #:with-listdir? #t
                         #:with-www? #f))

(define sample-static (static-site-sample))

(define (reverse-proxy-sample)
  (make-reverse-proxied-service-conf #:name 'probe
                                     #:upstream-name 'probe-proxy
                                     #:with-cors? #t
                                     #:with-rate-limit? #f
                                     #:with-gzip? #f))

(define sample-proxy (reverse-proxy-sample))

(define (certificate-domains-of block)
  "Return the domains a server block is expected to hold a certificate for."
  (nginx-server-configuration-server-name block))

(define nginx-suite
  (suite "Nginx Suite"

         (test "A static vhost serves its own directory"
               (assert-equal #:expect '("example.test")
                             #:got
                             (nginx-server-configuration-server-name
                              sample-static)
                             #:name
                             "with-www? #f leaves the bare name alone")
               (assert-equal #:expect "/srv/http/example.test"
                             #:got (nginx-server-configuration-root
                                    sample-static)
                             #:name
                             "The root is the site directory under /srv/http")
               (assert-equal #:expect "/etc/letsencrypt/live/example.test/fullchain.pem"
                             #:got
                             (nginx-server-configuration-ssl-certificate
                              sample-static)
                             #:name "The certificate follows the name")
               (assert-equal #:expect '("443 ssl" "443 quic")
                             #:got (nginx-server-configuration-listen
                                    sample-static)
                             #:name "TLS and QUIC are both served"))

         (test "A static vhost applies the shared security baseline"
               (assert-true (any-string-matches?
                             (strings-of (nginx-server-configuration-raw-content
                                          sample-static))
                             "Strict-Transport-Security")
                            #:name "HSTS is sent")
               (assert-true (any-string-matches?
                             (strings-of (nginx-server-configuration-raw-content
                                          sample-static))
                             "Content-Security-Policy")
                            #:name "A CSP is sent")
               (assert-true (any-string-matches?
                             (strings-of (nginx-server-configuration-raw-content
                                          sample-static))
                             "X-Content-Type-Options")
                            #:name "nosniff is sent")
               (assert-true (any-string-matches?
                             (strings-of (nginx-server-configuration-raw-content
                                          sample-static))
                             "http2 on;")
                            #:name "HTTP/2 is enabled")
               (assert-true (any-string-matches?
                             (strings-of (nginx-server-configuration-raw-content
                                          sample-static))
                             "limit_conn conn_per_ip 50;")
                            #:name "Per-IP connections are capped")
               (assert-true (any-string-matches?
                             (strings-of (nginx-server-configuration-raw-content
                                          sample-static))
                             "autoindex on;")
                            #:name "with-listdir? turns the index on")
               (assert-false (any-string-matches?
                              (strings-of (nginx-server-configuration-raw-content
                                           sample-static))
                              "limit_req zone=")
                             #:name "with-rate-limit? #f removes the request cap"))

         (test "Every vhost denies dotfiles"
               (assert-equal #:expect "~ /\\.(?!well-known)"
                             #:got
                             (nginx-location-configuration-uri
                              (car (nginx-server-configuration-locations
                                    sample-static)))
                             #:name "The dotfile rule is the first location")
               (assert-equal #:expect '("deny all;")
                             #:got
                             (nginx-location-configuration-body
                              (car (nginx-server-configuration-locations
                                    sample-static)))
                             #:name "and it denies everything"))

         (test "A reverse proxy passes the client's view upstream"
               (assert-equal #:expect '("probe.jointhefreeworld.org"
                                        "www.probe.jointhefreeworld.org")
                             #:got
                             (nginx-server-configuration-server-name
                              sample-proxy)
                             #:name "The domain defaults to jointhefreeworld.org")
               (assert-true (any-string-matches?
                             (location-strings sample-proxy)
                             "^proxy_pass http://probe-proxy;$")
                            #:name "The vhost proxies to its own upstream")
               (assert-true (any-string-matches?
                             (location-strings sample-proxy)
                             "proxy_set_header X-Forwarded-Proto \\$scheme;")
                            #:name "The upstream learns the client's scheme")
               (assert-true (any-string-matches?
                             (location-strings sample-proxy)
                             "proxy_set_header Connection \\$connection_upgrade;")
                            #:name "WebSocket upgrades survive the proxy")
               (assert-true (any-string-matches?
                             (location-strings sample-proxy)
                             "Cache-Control")
                            #:name "Static assets are cached upstream too")
               (assert-true (any-string-matches?
                             (strings-of (nginx-server-configuration-raw-content
                                          sample-proxy))
                             "gzip off;")
                            #:name "with-gzip? #f disables upstream gzip")
               (assert-true (any-string-matches?
                             (location-strings sample-proxy)
                             "Access-Control-Allow-Origin")
                            #:name "with-cors? adds the CORS header"))

         (test "The ACME vhost answers on plain HTTP and redirects"
               (assert-true (and (member "80"
                                         (append-map nginx-server-configuration-listen
                                                     minimal-blocks))
                                 #t)
                            #:name "The ACME vhost listens on port 80")
               (assert-false (any-string-matches?
                              (strings-of
                               (map nginx-server-configuration-raw-content
                                    minimal-blocks))
                              "ssl_session_cache")
                             #:name "Minimal mode emits no TLS vhost")
               (assert-true (any-string-matches?
                             (append-map location-strings minimal-blocks)
                             "return 301 https://\\$host\\$request_uri;")
                            #:name "Plain HTTP is redirected to HTTPS")
               (assert-true (and (member "grafana.jointhefreeworld.org"
                                         (append-map nginx-server-configuration-server-name
                                                     minimal-blocks))
                                 #t)
                            #:name "The ACME block answers for the Grafana name"))

         (test "Minimal mode keeps only the ACME and metrics vhosts"
               (assert-equal #:expect 2
                             #:got (length minimal-blocks)
                             #:name "A new machine gets two blocks")
               (assert-equal #:expect 17
                             #:got (length full-blocks)
                             #:name "A configured machine serves seventeen"))

         (test "Every vhost has a server block"
               (assert-equal #:expect 17
                             #:got (length full-blocks)
                             #:name "The count is the one the README documents")
               (assert-true (and jointhefreeworld-block #t)
                            #:name "jointhefreeworld.org is served")
               (assert-true (and byggsteg-block #t)
                            #:name "byggsteg is served")
               (assert-true (and torikomi-block #t)
                            #:name "torikomi is served")
               (assert-true (and symbanta-block #t)
                            #:name "symbanta is served"))

         (test "The static sites serve from /srv/http"
               (assert-equal #:expect "/srv/http/jointhefreeworld.org"
                             #:got (nginx-server-configuration-root
                                    jointhefreeworld-block)
                             #:name "A static site is rooted at its own name")
               (assert-equal #:expect "/srv/symbanta.jointhefreeworld.org"
                             #:got (nginx-server-configuration-root
                                    symbanta-block)
                             #:name "A site may point somewhere else"))

         (test "Restricted vhosts carry basic authentication"
               (assert-true (any-string-matches?
                             (strings-of (nginx-server-configuration-raw-content
                                          torikomi-block))
                             "auth_basic_user_file /srv/.htpasswd;")
                            #:name "torikomi is password protected"))

         (test "Every upstream a vhost names is declared"
               (let* ((blocks (append full-blocks minimal-blocks))
                      (targets (append-map proxy-targets blocks)))
                 (assert-equal #:expect 9
                               #:got (length upstreams)
                               #:name "Nine upstreams are declared")
                 (assert-equal #:expect '()
                               #:got
                               (remove (lambda (target)
                                         (member target upstream-names))
                                       targets)
                               #:name
                               "Each proxy_pass names a declared upstream")))

         (test "Upstreams are on loopback with keepalive"
               (assert-true (every (lambda (upstream)
                                     (any (lambda (server)
                                            (string-prefix? "127.0.0.1:" server))
                                          (nginx-upstream-configuration-servers
                                           upstream)))
                                   upstreams)
                            #:name "No upstream leaves the machine")
               (assert-true (and (every (lambda (upstream)
                                          (member "keepalive 64;"
                                                  (nginx-upstream-configuration-extra-content
                                                   upstream)))
                                        upstreams)
                                 #t)
                            #:name "Every upstream keeps connections alive")
               (assert-equal #:expect '("127.0.0.1:50002")
                             #:got
                             (nginx-upstream-configuration-servers
                              (find (lambda (upstream)
                                      (equal? (nginx-upstream-configuration-name
                                               upstream)
                                              "byggsteg-proxy"))
                                    upstreams))
                             #:name "byggsteg listens where its daemon does"))

         (test "The access log is nginx's logfmt format"
               (assert-equal #:expect 'wolk
                             #:got
                             (nginx-configuration-log-format full-capability)
                          #:name "The capability selects its own log format")
               (assert-true (any-string-matches?
                             (map nginx-log-format-configuration-format
                                  (nginx-configuration-log-formats
                                   full-capability))
                             "duration=\\$request_time")
                            #:name "Request time is logged")
               (assert-true (any-string-matches?
                             (map nginx-log-format-configuration-format
                                  (nginx-configuration-log-formats
                                   full-capability))
                             "urt=\\\\\"\\$upstream_response_time\\\\\"")
                            #:name "Upstream response time is logged")
               (assert-true (any-string-matches?
                             (map nginx-log-format-configuration-format
                                  (nginx-configuration-log-formats
                                   full-capability))
                             "status=\\$status")
                            #:name "The status code is logged"))

         (test "The global block carries the tuning and the zones"
               (assert-true (any-string-matches?
                             (nginx-configuration-extra-content full-capability)
                             "sendfile on;")
                            #:name "sendfile is on")
               (assert-true (any-string-matches?
                             (nginx-configuration-extra-content full-capability)
                             "limit_req_zone \\$binary_remote_addr zone=proxy_rate_limited")
                            #:name "The proxy rate-limit zone exists")
               (assert-true (any-string-matches?
                             (nginx-configuration-extra-content full-capability)
                             "limit_req_zone \\$binary_remote_addr zone=static_rate_limited")
                            #:name "The static rate-limit zone exists")
               (assert-true (any-string-matches?
                             (nginx-configuration-extra-content full-capability)
                             "map \\$http_upgrade \\$connection_upgrade")
                            #:name "The WebSocket map is defined")
               (assert-true (any-string-matches?
                             (nginx-configuration-extra-content full-capability)
                             "server_tokens off;")
                            #:name "The nginx version is hidden"))))

(define (spec)
  (veritas-run nginx-suite))
