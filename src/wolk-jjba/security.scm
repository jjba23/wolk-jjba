;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; The daily security audit.  One Shepherd timer, one Prometheus textfile,
;; no agent to keep running: whatever is wrong becomes a series, and the
;; alert rules in monitoring/alerting/alert-rules.yml turn the series into
;; mail.
;;
;; Five questions, asked once a day, in the order a human would ask them:
;;
;;   is this machine up to date?      the age of the running system
;;   does a CVE affect me?           (wolk-jjba cve), against CISA's
;;                                   known-exploited catalogue
;;   is SSH still locked down?       sshd -T, the *effective* config,
;;                                   not the file somebody meant to write
;;   did anything open up?           /etc/shadow and /etc/sudoers modes
;;   is the audit itself alive?      a timestamp, so a job that stopped
;;                                   running is an alert, not silence
;;
;; Two of those are deliberately about the machine rather than about
;; packages.  The weekly auto-upgrade in (wolk-jjba jobs) is the thing that
;; keeps a server patched, and the only honest measure of whether it is
;; working is how old the running generation is -- a job that fails every
;; Monday looks exactly like a job that has nothing to do, until the age
;; series says otherwise.
;;
;; The suspicious-activity half is not here: it is the `security-logs'
;; group of alert rules, over the auth.log lines Alloy already ships to
;; Loki.  Log lines are the right source for "somebody is trying
;; passwords" and the wrong source for "the kernel has an unpatched flaw",
;; and each lives where its data already is.
;;
;; The program runs as root because `sshd -T' reads the host keys and
;; /etc/sudoers is root-only; it writes nothing but the one textfile, and
;; the catalogue is fetched with TLS verified against the machine's own
;; bundle (/etc/ssl/certs), the same one the daemons use.
;;
;; Code:

(define-module (wolk-jjba security)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages guile-xyz)
  #:use-module (gnu packages ssh)
  #:use-module (ice-9 format)
  #:use-module (wolk-jjba cve)
  #:use-module (wolk-jjba jobs)
  #:use-module (wolk-jjba maintenance)
  #:export (security-capability
            security-service-type
            security-audit-program
            security-log-files))

;; `source-module-closure' defaults to Guix's own modules; the program below
;; needs (wolk-jjba cve) and must *not* drag (guix gexp) and the whole of
;; (gnu services) into the closure of a 200-line script.
(define (wolk-jjba-module? name)
  "Return #t for a module name that this repository provides."
  (and (pair? name) (eq? (car name) 'wolk-jjba)))

(define security-audit-program
  ;; `(json)' is guile-json, and the Guile that builds this program does
  ;; not carry it: without these extensions the derivation fails with
  ;; "no code for module (json)" at reconfigure time, which is the one
  ;; place a failure is expensive.
  (with-extensions (list guile-json-4)
   (program-file "security-audit"
    (with-imported-modules
     (source-module-closure '((wolk-jjba cve)) #:select? wolk-jjba-module?)
     #~(begin
         (use-modules (wolk-jjba cve)
                      (ice-9 format)
                      (ice-9 popen)
                      (ice-9 textual-ports)
                      (ice-9 time)
                      (srfi srfi-1)
                      (srfi srfi-13))

         (define manifest "/run/current-system/profile/manifest")
         (define metrics-file
           (string-append #$wolk-jjba-metrics-directory "/wolk_security.prom"))

         (define (log template . arguments)
           (apply format (current-error-port) template arguments))

         ;; A command and its output.  The status is kept as well as the
         ;; text: an audit that reads "sshd -T" through a failed exit
         ;; status would see an empty configuration and call it secure.
         (define (run-output program . arguments)
           (let* ((port (apply open-pipe* OPEN_READ program arguments))
                  (output (get-string-all port))
                  (status (close-pipe port)))
             (cons (status:exit-val status) output)))

         (define (metric name type help value)
           (list (format #f "# HELP ~a ~a~%" name help)
                 (format #f "# TYPE ~a ~a~%" name type)
                 (format #f "~a ~a~%" name value)))

         ;; --- the catalogue the news comes from ------------------------
         (setenv "SSL_CERT_FILE" "/etc/ssl/certs/ca-certificates.crt")
         (define feed-file (format #f "/tmp/wolk-security-cve-~a.json" (getpid)))
         (define feed
           (run-output #$(file-append curl "/bin/curl")
                       "-fsS" "--max-time" "90" "-o" feed-file #$kev-feed-url))
         (define feed-up? (zero? (car feed)))
         (unless feed-up?
           (log "security-audit: could not fetch CISA's catalogue (exit ~a): ~a~%"
                (car feed) (cdr feed)))

         ;; --- what this machine runs -----------------------------------
         (define packages
           (if (file-exists? manifest)
               (installed-package-names
                (call-with-input-file manifest get-string-all))
               '()))
         (unless (file-exists? manifest)
           (log "security-audit: ~a is missing, so no package was matched~%" manifest))

         (define since
           (strftime "%F" (localtime (- (current-time)
                                        (* kev-window-days 86400)))))
         (define matches
           (if (and feed-up? (pair? packages))
               (let ((feed-text (call-with-input-file feed-file get-string-all)))
                 (false-if-exception (delete-file feed-file))
                 (kev-matches feed-text packages #:since since))
               '()))
         (for-each (lambda (match)
                     (log "security-audit: ~a is exploited in the wild and names ~a~%"
                          (car match) (cdr match)))
                   matches)

         ;; --- SSH, as the daemon will run it ----------------------------
         (define sshd
           (run-output #$(file-append openssh-sans-x "/sbin/sshd") "-T"))
         (define sshd-config (if (zero? (car sshd)) (cdr sshd) ""))
         (unless (zero? (car sshd))
           (log "security-audit: sshd -T failed (exit ~a): ~a~%"
                (car sshd) (cdr sshd)))
         (define (weak? setting)
           (string-contains sshd-config (string-append setting " yes")))
         (define weak-settings
           (filter weak? '("passwordauthentication" "permitrootlogin"
                           "x11forwarding")))
         (for-each (lambda (setting)
                     (log "security-audit: sshd still allows ~a~%" setting))
                   weak-settings)

         ;; --- files that must stay root-only ----------------------------
         (define (exposed? path)
           (catch #t
             (lambda () (not (zero? (logand (stat:mode (stat path)) #o007))))
             (lambda arguments #f)))
         (define exposed
           (filter exposed? '("/etc/shadow" "/etc/sudoers")))
         (for-each (lambda (path)
                     (log "security-audit: ~a is readable by somebody other than its owner and group~%"
                          path))
                   exposed)

         ;; --- how far behind the weekly upgrade is ----------------------
         ;; -1 when /run/current-system cannot be read: a number nobody can
         ;; trust is worse than a number that is obviously wrong, and the
         ;; age alert ignores -1.
         (define system-age
           (catch #t
             (lambda ()
               (max 0 (- (current-time)
                         (stat:mtime (stat "/run/current-system")))))
             (lambda arguments -1)))

         (define lines
           (append
            (metric "wolk_security_audit_timestamp_seconds" "gauge"
                    "When the security audit last finished." (current-time))
            (metric "wolk_system_generation_age_seconds" "gauge"
                    "Age in seconds of the running system generation; -1 when it cannot be read."
                    system-age)
            (metric "wolk_cve_feed_up" "gauge"
                    "1 when the known-exploited catalogue could be fetched."
                    (if feed-up? 1 0))
            (metric "wolk_cve_kev_matches" "gauge"
                    "Recently published exploited vulnerabilities naming a package this host runs."
                    (length matches))
            (append-map (lambda (match)
                          (list (format #f "wolk_cve_kev_match{cve=\"~a\",package=\"~a\"} 1~%"
                                        (car match) (cdr match))))
                        matches)
            (metric "wolk_security_sshd_weak_settings" "gauge"
                    "Weak settings in sshd's effective configuration."
                    (length weak-settings))
            (append-map (lambda (setting)
                          (list (format #f "wolk_security_sshd_weak{setting=\"~a\"} 1~%"
                                        setting)))
                        weak-settings)
            (metric "wolk_security_permissions_ok" "gauge"
                    "1 when the files that must stay root-only are."
                    (if (null? exposed) 1 0))))

         ;; node exporter rejects a textfile that is being written, and a
         ;; rejected file makes every series in it vanish -- so the file is
         ;; replaced by a rename, the same way the other jobs do it.
         (catch #t
           (lambda ()
             (let ((temporary (string-append metrics-file ".tmp")))
               (call-with-output-file temporary
                 (lambda (port)
                   (for-each (lambda (line) (display line port)) lines)))
               (chmod temporary #o644)
               (rename-file temporary metrics-file)))
           (lambda (key . arguments)
             (log "security-audit: could not write ~a: ~a~%" metrics-file key)
             (exit 1))))))))

(define security-audit-service
  (make-timer-service
   #:name 'security-audit
   ;; An hour after the weekly upgrade's slot on Monday, and in the quiet
   ;; part of the night otherwise: the audit reads the network, the whole
   ;; root file system's metadata and sshd, and none of that is urgent.
   #:schedule "20 5 * * *"
   #:program security-audit-program
   #:requirement '(user-processes file-systems networking)
   #:max-duration 900
   #:documentation
   "Check for updates and exploited CVEs, audit sshd and the root-only files, and publish the results."))

(define security-log-files
  (list (format #f "/var/log/wolk-jjba/~a.log"
                (car (shepherd-service-provision security-audit-service)))))

(define security-service-type
  (service-type
   (name 'wolk-jjba-security)
   (extensions
    (list (service-extension
           shepherd-root-service-type
           (const (list security-audit-service)))
          (service-extension
           log-rotation-service-type
           (const security-log-files))))
   (default-value '())
   (description
    "Audit the host once a day: published exploited CVEs against the
installed packages, the effective SSH configuration, the age of the
running system generation and the modes of the root-only files.")))

(define (security-capability)
  (service security-service-type))
