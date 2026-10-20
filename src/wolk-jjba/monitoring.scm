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
;; Native observability stack: Prometheus, Loki, Grafana, Grafana Alloy
;; and Tempo, each run by the Shepherd.  There are no containers and no
;; Docker/Podman in this stack.
;;
;; The five binaries come from (wolk-jjba monitoring-packages), where
;; they are pinned by version and hash.  Prometheus, Loki, Grafana and
;; Tempo are static; Alloy is run through the Guix glibc loader by a
;; wrapper.
;;
;; Ports (all bound to localhost; nginx terminates TLS):
;;
;;   Prometheus 127.0.0.1:59090
;;   Loki       127.0.0.1:53100
;;   Grafana    127.0.0.1:53000
;;   Tempo      127.0.0.1:53200 (HTTP), 53201 (gRPC), 14317/14318 (OTLP)
;;   Alloy      127.0.0.1:12345 (debug UI), 4317/4318 (OTLP)
;;
;; Logs are written to /var/log/wolk-jjba/<name>.log and registered with
;; the Shepherd log rotation service.  Alloy tails the files routed by
;; (wolk-jjba logging) and pushes them to Loki.
;;
;; OpenTelemetry: Alloy accepts OTLP on the standard ports (4317 gRPC,
;; 4318 HTTP) and fans the three signals out to Prometheus (metrics),
;; Loki (logs) and Tempo (traces).  Tempo listens on non-standard OTLP
;; ports so the two receivers cannot collide; only Alloy talks to it.
;;
;; Grafana is provisioned from the store: data sources, dashboards and
;; the alerting resources (contact point, notification policies and
;; rules).  Alert e-mail uses SMTP credentials read from
;; /etc/secrets/grafana-smtp when the Grafana service starts.
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

(define tempo-config
  (monitoring-file "tempo.yml"))

(define herd-logs-dashboard
  (monitoring-file "dashboards/herd-daemons-logs.json"))

(define host-dashboard
  (monitoring-file "dashboards/host-cpu-memory.json"))

(define health-dashboard
  (monitoring-file "dashboards/shepherd-daemons-health.json"))

(define network-dashboard
  (monitoring-file "dashboards/network-http.json"))

(define storage-dashboard
  (monitoring-file "dashboards/storage-retention.json"))

(define datasources-config
  (monitoring-file "datasources.yml"))

(define alert-rules-config
  (monitoring-file "alerting/alert-rules.yml"))

(define contact-points-config
  (monitoring-file "alerting/contact-points.yml"))

(define notification-policies-config
  (monitoring-file "alerting/notification-policies.yml"))

;; Grafana's provisioning tree.  Grafana only reads provider files from
;; the provisioning/dashboards/ directory, and the provider points at the
;; directory holding the dashboard JSON, whose store path is written into
;; the file at build time (so it does not have to be guessed at
;; configuration time).
(define grafana-provisioning
  (computed-file "grafana-provisioning"
    (with-imported-modules '((guix build utils))
      #~(begin
          (use-modules (guix build utils)
                       (ice-9 format))
          (define dashboards
            (string-append #$output "/dashboards/json"))
          (mkdir-p (string-append #$output "/datasources"))
          (mkdir-p (string-append #$output "/alerting"))
          ;; Grafana logs an error when the plugins provisioning
          ;; directory is absent; an empty one is the supported shape.
          (mkdir-p (string-append #$output "/plugins"))
          (mkdir-p dashboards)
          (mkdir-p (string-append #$output "/dashboards"))
          (copy-file #$datasources-config
                     (string-append #$output "/datasources/datasources.yml"))
          (copy-file #$alert-rules-config
                     (string-append #$output "/alerting/alert-rules.yml"))
          (copy-file #$contact-points-config
                     (string-append #$output "/alerting/contact-points.yml"))
          (copy-file #$notification-policies-config
                     (string-append #$output
                                    "/alerting/notification-policies.yml"))
          (copy-file #$herd-logs-dashboard
                     (string-append dashboards "/herd-daemons-logs.json"))
          (copy-file #$host-dashboard
                     (string-append dashboards "/host-cpu-memory.json"))
          (copy-file #$health-dashboard
                     (string-append dashboards
                                    "/shepherd-daemons-health.json"))
          (copy-file #$network-dashboard
                     (string-append dashboards "/network-http.json"))
          (copy-file #$storage-dashboard
                     (string-append dashboards "/storage-retention.json"))
          (call-with-output-file (string-append #$output
                                                "/dashboards/provider.yml")
            (lambda (port)
              (format port "apiVersion: 1~%")
              (format port "providers:~%")
              (format port "  - name: wolk-jjba~%")
              (format port "    orgId: 1~%")
              (format port "    folder: wolk-jjba~%")
              (format port "    type: file~%")
              (format port "    disableDeletion: false~%")
              (format port "    updateIntervalSeconds: 30~%")
              (format port "    allowUiUpdates: true~%")
              (format port "    options:~%")
              (format port "      path: ~a~%" dashboards)))))))

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
            (format port "[dashboards]~%")
            (format port "default_home_dashboard_path = ~a/dashboards/json/host-cpu-memory.json~%"
                    #$grafana-provisioning)
            (format port "[unified_alerting]~%enabled = true~%")
            ;; Credentials come from /etc/secrets/grafana-smtp; the
            ;; Shepherd start thunk exports them before Grafana runs, so
            ;; the password never lands in the store.
            (format port "[smtp]~%")
            (format port "enabled = $__env{GRAFANA_SMTP_ENABLED}~%")
            ;; Grafana expects host and port together, e.g.
            ;; smtp.example.org:587.
            (format port "host = $__env{GRAFANA_SMTP_HOST}~%")
            (format port "user = $__env{GRAFANA_SMTP_USER}~%")
            (format port "password = $__env{GRAFANA_SMTP_PASSWORD}~%")
            (format port "from_address = $__env{GRAFANA_SMTP_FROM}~%")
            (format port "from_name = wolk-jjba~%")
            (format port "startTLS_policy = OpportunisticStartTLS~%")
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
         (shell (file-append shadow "/sbin/nologin")))
        (user-group (name "tempo") (system? #t))
        (user-account
         (name "tempo")
         (group "tempo")
         (system? #t)
         (home-directory "/var/lib/tempo")
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
                            "--web.listen-address=127.0.0.1:59090"
                            ;; Alloy writes OTLP metrics here.
                            "--web.enable-remote-write-receiver")
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
         (documentation "Run the Grafana dashboard and alerting server.")
         (start #~(lambda args
                    (use-modules (ice-9 rdelim))
                    ;; /etc/secrets/grafana-smtp is four lines: host:port,
                    ;; user, password and sender address.  The
                    ;; start thunk runs as root, before Grafana drops to
                    ;; its own user, so the file does not have to be
                    ;; readable by `grafana'.
                    (define (read-secret-lines file)
                      (if (file-exists? file)
                          (call-with-input-file file
                            (lambda (port)
                              (let loop ((lines '()))
                                (let ((line (read-line port)))
                                  (if (eof-object? line)
                                      (reverse lines)
                                      (loop (cons line lines)))))))
                          '()))
                    (define (line-or lines index fallback)
                      (if (> (length lines) index)
                          (list-ref lines index)
                          fallback))
                    (define smtp
                      (read-secret-lines "/etc/secrets/grafana-smtp"))
                    (define smtp-enabled?
                      (and (not (null? smtp))
                           (not (string=? (line-or smtp 0 "") ""))))
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
                      #:environment-variables
                      (list "HOME=/var/lib/grafana"
                            (string-append
                             "GRAFANA_SMTP_ENABLED="
                             (if smtp-enabled? "true" "false"))
                            (string-append "GRAFANA_SMTP_HOST="
                                           (line-or smtp 0 ""))
                            (string-append "GRAFANA_SMTP_USER="
                                           (line-or smtp 1 ""))
                            (string-append "GRAFANA_SMTP_PASSWORD="
                                           (line-or smtp 2 ""))
                            (string-append "GRAFANA_SMTP_FROM="
                                           (line-or smtp 3 "")))
                      #:log-file "/var/log/wolk-jjba/grafana.log")
                     args)))
         (stop #~(make-kill-destructor))
         (respawn? #t))))

(define (alloy-shepherd-service)
  (list (shepherd-service
         (provision '(alloy))
         (requirement '(user-processes networking))
         (documentation
          "Run Grafana Alloy: ship logs to Loki and accept OTLP from the host.")
         (start #~(lambda args
                    #$(prepare-directory "/var/lib/alloy" "alloy")
                    ((make-forkexec-constructor
                      (list #$(file-append alloy "/bin/alloy")
                            "run"
                            "--storage.path=/var/lib/alloy"
                            "--server.http.listen-addr=127.0.0.1:12345"
                            "--disable-reporting"
                            #$alloy-config)
                      #:user "alloy"
                      #:group "alloy"
                      #:environment-variables '("HOME=/var/lib/alloy")
                      #:log-file "/var/log/wolk-jjba/alloy.log")
                     args)))
         (stop #~(make-kill-destructor))
         (respawn? #t))))

(define (tempo-shepherd-service)
  (list (shepherd-service
         (provision '(tempo))
         (requirement '(user-processes networking))
         (documentation "Run the Tempo trace store.")
         (start #~(lambda args
                    #$(prepare-directory "/var/lib/tempo" "tempo")
                    #$(prepare-directory "/var/lib/tempo/blocks" "tempo")
                    #$(prepare-directory "/var/lib/tempo/wal" "tempo")
                    #$(prepare-directory "/var/lib/tempo/work" "tempo")
                    #$(prepare-directory "/var/lib/tempo/live-store" "tempo")
                    #$(prepare-directory "/var/lib/tempo/live-store/wal" "tempo")
                    ((make-forkexec-constructor
                      (list #$(file-append tempo "/bin/tempo")
                            (string-append "-config.file=" #$tempo-config))
                      #:user "tempo"
                      #:group "tempo"
                      #:environment-variables '("HOME=/var/lib/tempo")
                      #:log-file "/var/log/wolk-jjba/tempo.log")
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
                     (tempo-shepherd-service)
                     (alloy-shepherd-service))))
          (service-extension
           account-service-type
           (const monitoring-accounts))
          (service-extension
           log-rotation-service-type
           (const '("/var/log/wolk-jjba/prometheus.log"
                    "/var/log/wolk-jjba/loki.log"
                    "/var/log/wolk-jjba/grafana.log"
                    "/var/log/wolk-jjba/tempo.log"
                    "/var/log/wolk-jjba/alloy.log")))))
   (default-value '())
   (description
    "Run the native Prometheus, Loki, Grafana, Tempo and Alloy
observability stack.")))
