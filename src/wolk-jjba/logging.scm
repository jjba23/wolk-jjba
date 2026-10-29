;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Centralised log routing for the wolk-jjba instance.
;;
;; GNU Guix's %base-services run the Shepherd's in-process system log
;; (shepherd-system-log-service-type).  It reads the messages that
;; daemons write to /dev/log and writes each one to the files returned
;; by a `message-destination' procedure.  The default procedure funnels
;; almost everything into a single /var/log/messages, which makes the
;; file impossible to read or filter.
;;
;; This module replaces that procedure with
;; `wolk-jjba-message-destination', which routes authentication, mail,
;; kernel, cron and daemon messages to dedicated files.  Messages that
;; matter most (emergency and alert) are still written to the console
;; and to /var/log/messages, and any facility we do not single out keeps
;; landing in /var/log/messages as the catch-all.
;;
;; Per-daemon stdout/stderr is additionally redirected to
;; /var/log/wolk-jjba/<service>.log through the Shepherd `#:log-file'
;; constructor argument (see (wolk-jjba prelude)), so a noisy daemon
;; never spills into /var/log/messages at all.
;;
;; The Shepherd's log rotation service, enabled by default in
;; %base-services, knows about both the files created by the system log
;; and those created through `#:log-file', so these files are rotated
;; automatically.

(define-module (wolk-jjba logging)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:export (wolk-jjba-message-destination
            system-log-capability))

;; A g-expression evaluating to the procedure the Shepherd calls for
;; every message read from /dev/log.  It must return the list of files
;; the message is to be written to; returning the empty list drops the
;; message.  The generated Shepherd service already imports
;; (shepherd service system-log), so the accessors and facility/priority
;; constructors are in scope here.
(define wolk-jjba-message-destination
  #~(lambda (message)
      (let ((facility (system-log-message-facility message))
            (priority (system-log-message-priority message)))
        (cond
         ;; Keep the most urgent messages on the console, and archive
         ;; them with everything else that is not singled out below.
         ((member priority
                  (list (system-log-priority emergency)
                        (system-log-priority alert)))
          '("/dev/console" "/var/log/messages"))
         ;; Authentication and authorization.
         ((member facility
                  (list (system-log-facility authorization)
                        (system-log-facility authorization/private)))
          '("/var/log/auth.log"))
         ;; Mail.
         ((eqv? facility (system-log-facility mail))
          '("/var/log/mail.log"))
         ;; Kernel.
         ((eqv? facility (system-log-facility kernel))
          '("/var/log/kern.log"))
         ;; Scheduled jobs.
         ((eqv? facility (system-log-facility cron))
          '("/var/log/cron.log"))
         ;; Background daemons (mpd, certbot, nginx helpers, ...).
         ((eqv? facility (system-log-facility daemon))
          '("/var/log/daemon.log"))
         ;; Everything else (user-level programs, unknown facilities).
         (else
          '("/var/log/messages"))))))

(define (system-log-capability services)
  "Return SERVICES, the full wolk-jjba service list, with the Shepherd
system log reconfigured to route messages through
`wolk-jjba-message-destination'."
  (modify-services services
    (shepherd-system-log-service-type config =>
      (system-log-configuration
        (inherit config)
        (message-destination wolk-jjba-message-destination)))))
