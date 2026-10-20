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
;; /etc/secrets/grafana-smtp when the Grafana service starts.  Grafana
;; refuses to boot on a malformed [smtp] from_address even with SMTP
;; disabled, so the start thunk validates the sender line and falls back
;; to a reserved-TLD address instead of letting the service crash-loop.
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
  #:use-module (ice-9 format)
  #:use-module (wolk-jjba monitoring-packages)
  #:export (wolk-jjba-monitoring-service-type grafana-ini-text))

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

;; The configuration file as text.  It is a pure function of the
;; provisioning directory so that it can be read -- and checked -- by the
;; test suite without building a store item; grafana-config below is the
;; store item that writes it.  The directory is a store path that only
;; exists at build time, so the function writes @PROVISIONING@ where it
;; belongs and the build substitutes the real path.
(define* (grafana-ini-text #:key (provisioning "@PROVISIONING@"))
  (string-append
    "[server]\nhttp_addr = 127.0.0.1\nhttp_port = 53000\n"
    "domain = grafana.jointhefreeworld.org\n"
    "root_url = https://grafana.jointhefreeworld.org/\n"
    "[paths]\ndata = /var/lib/grafana\n"
    "logs = /var/log/grafana\n"
    "plugins = /var/lib/grafana/plugins\n"
    (string-append "provisioning = " provisioning "\n")
    "[dashboards]\n"
    (string-append
     "default_home_dashboard_path = "
     provisioning
     "/dashboards/json/host-cpu-memory.json\n")
    "[unified_alerting]\nenabled = true\n"
    ;; Safe defaults: a valid reserved-TLD sender and SMTP off.  The
    ;; start thunk overrides these with GF_SMTP_* environment variables
    ;; after validating /etc/secrets/grafana-smtp, so the password never
    ;; lands in the store and a missing or malformed secret can never
    ;; crash-loop Grafana.
    "[smtp]\n"
    "enabled = false\n"
    "host =\n"
    "user =\n"
    "password =\n"
    "from_address = grafana@wolk-jjba.invalid\n"
    "from_name = wolk-jjba\n"
    "startTLS_policy = OpportunisticStartTLS\n"
    "[log]\nmode = console\nlevel = info\n"
    "[analytics]\nreporting_enabled = false\n"
    "check_for_updates = false\n"
    "[security]\n"
    "csrf_trusted_origins = grafana.jointhefreeworld.org www.grafana.jointhefreeworld.org\n"
    "csrf_additional_headers = X-Forwarded-Host\n"
    "cookie_samesite = lax\n"))

(define grafana-config
  (computed-file "grafana.ini"
    #~(begin
        (use-modules (ice-9 format) (ice-9 string-fun))
        (call-with-output-file #$output
          (lambda (port)
            (display (string-replace-substring #$(grafana-ini-text)
                                               "@PROVISIONING@"
                                               #$grafana-provisioning)
                     port))))))

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

;; Every service's stdout/stderr goes to /var/log/wolk-jjba/<name>.log
;; through the Shepherd's #:log-file argument (see (wolk-jjba prelude)),
;; and Alloy tails that directory.  The Shepherd opens the file itself,
;; as root, before it drops to the service's user, and it creates it mode
;; 0640 with group root -- `#:file-creation-mask' is applied only after
;; the file is open, so it cannot widen it.  The unprivileged `alloy'
;; user therefore cannot read a single one of those files: Alloy keeps
;; tailing and ships nothing, the Daemon selector in the logs dashboard
;; stays empty, and a query for a daemon in Explore returns no data even
;; though `tail /var/log/wolk-jjba/<name>.log' works for root.  The same
;; holds for the routed system logs (/var/log/auth.log and friends),
;; which the Shepherd's system-log service writes the same way.
;;
;; Two things make them readable without running Alloy as root:
;;
;;   - the directory is made set-group-ID and owned by group `alloy', so
;;     every file created in it from now on (a daemon that starts after
;;     Alloy, a log the rotation service recreates) inherits that group
;;     and is readable at mode 0640 even though it is still root-owned;
;;   - the files that already exist are repaired in place, which covers
;;     the ones created earlier in the same boot, and the system log
;;     files, which cannot live in a set-group-ID directory.
;;
;; Mode 0644 also restores what the README promises the human: the files
;; stay readable with `tail' and `grep' as the login user.
(define prepare-log-access
  #~(begin
      (use-modules (guix build utils))
      (let* ((entry (getgrnam "alloy"))
             (alloy (and entry (vector-ref entry 2)))
             ;; `chown' clears the set-group-ID bit, so the order matters.
             (share (lambda (file)
                      (chown file 0 alloy)
                      (chmod file #o644))))
        (when alloy
          (let ((directory "/var/log/wolk-jjba"))
            (mkdir-p directory)
            (chown directory 0 alloy)
            (chmod directory #o2755)
            (for-each share
                      (find-files directory ".*\\.log")))
          (for-each (lambda (file)
                      (when (file-exists? file)
                        (share file)))
                    '("/var/log/messages"
                      "/var/log/auth.log"
                      "/var/log/mail.log"
                      "/var/log/kern.log"
                      "/var/log/cron.log"
                      "/var/log/daemon.log"))))))

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
         ;; Guix compiles a service's start thunk into a file of its own.  A
         ;; `use-modules' *inside* that thunk is expanded when the file is
         ;; compiled and dropped at run time, so bindings such as
         ;; `string-match', `string-trim-both', `read-line' and `format'
         ;; would be unbound when the service starts.  Declaring the modules
         ;; on the service makes Guix emit them as top-level imports of the
         ;; generated file, before the thunk is even defined.
         (modules (append %default-modules
                          '((ice-9 rdelim) (ice-9 regex) (ice-9 format)
                            (srfi srfi-13))))
         (start #~(lambda args
                    ;; /etc/secrets/grafana-smtp is four lines: host:port,
                    ;; user, password and sender address.  The
                    ;; start thunk runs as root, before Grafana drops to
                    ;; its own user, so the file does not have to be
                    ;; readable by `grafana'.  Lines are trimmed: a file
                    ;; edited on another OS ends them with CRLF, and the
                    ;; stray return would otherwise make the sender look
                    ;; malformed (Grafana would refuse to start).
                    (define (read-secret-lines file)
                      (if (file-exists? file)
                          (call-with-input-file file
                            (lambda (port)
                              (let loop ((lines '()))
                                (let ((line (read-line port)))
                                  (if (eof-object? line)
                                      (reverse lines)
                                      (loop (cons (string-trim-both line)
                                                  lines)))))))
                          '()))
                    (define (line-or lines index fallback)
                      (if (> (length lines) index)
                          (list-ref lines index)
                          fallback))
                    ;; Grafana validates [smtp] from_address even when
                    ;; SMTP is disabled: an empty or malformed value makes
                    ;; `grafana server' exit with "invalid email address
                    ;; for SMTP from_address config", and the Shepherd then
                    ;; respawns it forever.  The check below is deliberately
                    ;; narrower than RFC 5322 but matches what Grafana
                    ;; accepts: a dotted domain whose labels do not start or
                    ;; end with a hyphen, and a local part without leading,
                    ;; trailing or doubled dots.  A false negative only
                    ;; disables alert mail (with a warning), whereas a false
                    ;; positive would crash-loop the service, so anything
                    ;; doubtful is treated as malformed.
                    (define (sender-address? value)
                      (and (string? value)
                           (if (string-match
                                "^[A-Za-z0-9_%+-]+(\\.[A-Za-z0-9_%+-]+)*@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.)+[A-Za-z]{2,}$"
                                value)
                               #t #f)))
                    (define placeholder-sender "grafana@wolk-jjba.invalid")
                    (define smtp
                      (read-secret-lines "/etc/secrets/grafana-smtp"))
                    (define sender (line-or smtp 3 ""))
                    (define valid-sender? (sender-address? sender))
                    (define smtp-enabled?
                      (and (not (null? smtp))
                           (not (string=? (line-or smtp 0 "") ""))
                           valid-sender?))
                    (when (and (not (null? smtp)) (not valid-sender?))
                      (let ((warning
                             (format #f
                                     "grafana: warning: line 4 of /etc/secrets/grafana-smtp must be a plain e-mail address (got ~s).  SMTP is disabled and ~a is used as the sender.~%"
                                     sender placeholder-sender)))
                        (format (current-error-port) "~a" warning)
                        ;; Also leave it where the operator looks, and where
                        ;; Alloy ships it: the service log.  The directory
                        ;; normally exists; create it only when missing, so
                        ;; that an EEXIST cannot abort the append below.
                        (false-if-exception
                         (begin
                           (unless (file-exists? "/var/log/wolk-jjba")
                             (mkdir "/var/log/wolk-jjba"))
                           (let ((port (open-file
                                        "/var/log/wolk-jjba/grafana.log" "a")))
                             (display warning port)
                             (close-port port))))))
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
                             "GF_SMTP_ENABLED="
                             (if smtp-enabled? "true" "false"))
                            (string-append "GF_SMTP_HOST="
                                           (line-or smtp 0 ""))
                            (string-append "GF_SMTP_USER="
                                           (line-or smtp 1 ""))
                            (string-append "GF_SMTP_PASSWORD="
                                           (line-or smtp 2 ""))
                            (string-append "GF_SMTP_FROM_ADDRESS="
                                           (if valid-sender?
                                               sender
                                               placeholder-sender))
                            "GF_SMTP_FROM_NAME=wolk-jjba")
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
                    ;; Alloy is the only unprivileged reader of the log
                    ;; files the Shepherd creates for the other daemons,
                    ;; so it needs them to be readable; see
                    ;; `prepare-log-access' above.
                    #$prepare-log-access
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
