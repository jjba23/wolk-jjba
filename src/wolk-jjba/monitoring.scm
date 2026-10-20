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
;; Native observability stack: Prometheus, Loki, Grafana and Grafana
;; Alloy, each run by the Shepherd.  There are no containers and no
;; Docker/Podman in this stack.
;;
;; The four binaries come from (wolk-jjba monitoring-packages), where
;; they are pinned by version and hash.  Prometheus, Loki and Grafana
;; are static; Alloy is run through the Guix glibc loader by a wrapper.
;;
;; Ports (all bound to localhost; nginx terminates TLS):
;;
;;   Prometheus 127.0.0.1:59090
;;   Loki       127.0.0.1:53100
;;   Grafana    127.0.0.1:53000
;;   Alloy      127.0.0.1:12345 (debug UI)
;;
;; Logs are written to /var/log/wolk-jjba/<name>.log and registered with
;; the Shepherd log rotation service.  Alloy tails the files routed by
;; (wolk-jjba logging) and pushes them to Loki.
;;
;; Code:

(define-module (wolk-jjba monitoring)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu packages admin)
  #:use-module (wolk-jjba monitoring-packages)
  #:export (wolk-jjba-monitoring-service-type))

(define (monitoring-file name)
  (local-file
   (assume-valid-file-name
    (string-append (getcwd) "/src/wolk-jjba/monitoring/" name))))

(define prometheus-config
  (monitoring-file "prometheus.yml"))

(define loki-config
  (monitoring-file "loki.yml"))

(define alloy-config
  (monitoring-file "alloy.alloy"))

(define datasources-config
  (monitoring-file "datasources.yml"))

(define grafana-provisioning
  (computed-file "grafana-provisioning"
    (with-imported-modules '((guix build utils))
      #~(begin
          (use-modules (guix build utils))
          (mkdir-p (string-append #$output "/datasources"))
          (copy-file #$datasources-config
                     (string-append #$output "/datasources/datasources.yml"))))))

(define grafana-config
  (computed-file "grafana.ini"
    #~(begin
        (use-modules (ice-9 format))
        (call-with-output-file #$output
          (lambda (port)
            (format port "[server]~%http_addr = 127.0.0.1~%http_port = 53000~%")
            (format port "domain = grafana.jointhefreeworld.org~%")
            (format port "root_url = https://grafana.jointhefreeworld.org/~%")
            (format port "[paths]~%data = /var/lib/grafana~%")
            (format port "logs = /var/log/grafana~%")
            (format port "plugins = /var/lib/grafana/plugins~%")
            (format port "provisioning = ~a~%" #$grafana-provisioning)
            (format port "[log]~%mode = console~%level = info~%")
            (format port "[analytics]~%reporting_enabled = false~%")
            (format port "check_for_updates = false~%")
            (format port "[security]~%")
            (format port "csrf_trusted_origins = grafana.jointhefreeworld.org www.grafana.jointhefreeworld.org~%")
            (format port "csrf_additional_headers = X-Forwarded-Host~%")
            (format port "cookie_samesite = lax~%"))))))

(define monitoring-accounts
  (list (user-group (name "prometheus") (system? #t))
        (user-account
         (name "prometheus")
         (group "prometheus")
         (system? #t)
         (home-directory "/var/lib/prometheus")
         (shell (file-append shadow "/sbin/nologin")))
        (user-group (name "loki") (system? #t))
        (user-account
         (name "loki")
         (group "loki")
         (system? #t)
         (home-directory "/var/lib/loki")
         (shell (file-append shadow "/sbin/nologin")))
        (user-group (name "grafana") (system? #t))
        (user-account
         (name "grafana")
         (group "grafana")
         (system? #t)
         (home-directory "/var/lib/grafana")
         (shell (file-append shadow "/sbin/nologin")))
        (user-group (name "alloy") (system? #t))
        (user-account
         (name "alloy")
         (group "alloy")
         (system? #t)
         (home-directory "/var/lib/alloy")
         (shell (file-append shadow "/sbin/nologin")))))

(define* (prepare-directory directory user #:optional (mode #o755))
  #~(begin
      (use-modules (guix build utils))
      (mkdir-p #$directory)
      (chmod #$directory #$mode)
      (let ((pw (getpwnam #$user)))
        (chown #$directory (vector-ref pw 2) (vector-ref pw 3)))))

(define (prometheus-shepherd-service)
  (list (shepherd-service
         (provision '(prometheus))
         (requirement '(user-processes networking))
         (documentation "Run the Prometheus server.")
         (start #~(lambda args
                    #$(prepare-directory "/var/lib/prometheus" "prometheus")
                    ((make-forkexec-constructor
                      (list #$(file-append prometheus "/bin/prometheus")
                            (string-append "--config.file=" #$prometheus-config)
                            "--storage.tsdb.path=/var/lib/prometheus"
                            "--web.listen-address=127.0.0.1:59090")
                      #:user "prometheus"
                      #:group "prometheus"
                      #:environment-variables '("HOME=/var/lib/prometheus")
                      #:log-file "/var/log/wolk-jjba/prometheus.log")
                     args)))
         (stop #~(make-kill-destructor))
         (respawn? #t))))

(define (loki-shepherd-service)
  (list (shepherd-service
         (provision '(loki))
         (requirement '(user-processes networking))
         (documentation "Run the Loki log aggregation server.")
         (start #~(lambda args
                    #$(prepare-directory "/var/lib/loki" "loki")
                    ((make-forkexec-constructor
                      (list #$(file-append loki "/bin/loki")
                            (string-append "-config.file=" #$loki-config))
                      #:user "loki"
                      #:group "loki"
                      #:environment-variables '("HOME=/var/lib/loki")
                      #:log-file "/var/log/wolk-jjba/loki.log")
                     args)))
         (stop #~(make-kill-destructor))
         (respawn? #t))))

(define (grafana-shepherd-service)
  (list (shepherd-service
         (provision '(grafana))
         (requirement '(user-processes networking))
         (documentation "Run the Grafana dashboard server.")
         (start #~(lambda args
                    #$(prepare-directory "/var/lib/grafana" "grafana")
                    #$(prepare-directory "/var/log/grafana" "grafana")
                    ((make-forkexec-constructor
                      (list #$(file-append grafana "/bin/grafana")
                            "server"
                            (string-append "--homepath="
                                           #$(file-append grafana "/share/grafana"))
                            (string-append "--config=" #$grafana-config))
                      #:user "grafana"
                      #:group "grafana"
                      #:environment-variables '("HOME=/var/lib/grafana")
                      #:log-file "/var/log/wolk-jjba/grafana.log")
                     args)))
         (stop #~(make-kill-destructor))
         (respawn? #t))))

(define (alloy-shepherd-service)
  (list (shepherd-service
         (provision '(alloy))
         (requirement '(user-processes networking))
         (documentation "Run Grafana Alloy and ship logs to Loki.")
         (start #~(lambda args
                    #$(prepare-directory "/var/lib/alloy" "alloy")
                    ((make-forkexec-constructor
                      (list #$(file-append alloy "/bin/alloy")
                            "run"
                            "--storage.path=/var/lib/alloy"
                            #$alloy-config)
                      #:user "alloy"
                      #:group "alloy"
                      #:environment-variables '("HOME=/var/lib/alloy")
                      #:log-file "/var/log/wolk-jjba/alloy.log")
                     args)))
         (stop #~(make-kill-destructor))
         (respawn? #t))))

(define wolk-jjba-monitoring-service-type
  (service-type
   (name 'wolk-jjba-monitoring)
   (extensions
    (list (service-extension
           shepherd-root-service-type
           (lambda (_)
             (append (prometheus-shepherd-service)
                     (loki-shepherd-service)
                     (grafana-shepherd-service)
                     (alloy-shepherd-service))))
          (service-extension
           account-service-type
           (const monitoring-accounts))
          (service-extension
           log-rotation-service-type
           (const '("/var/log/wolk-jjba/prometheus.log"
                    "/var/log/wolk-jjba/loki.log"
                    "/var/log/wolk-jjba/grafana.log"
                    "/var/log/wolk-jjba/alloy.log")))))
   (default-value '())
   (description
    "Run the native Prometheus, Loki, Grafana and Alloy observability stack.")))
