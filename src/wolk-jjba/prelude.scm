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
;; Shared helpers used by several capabilities:
;;
;;   - wolk-jjba-log-directory, where per-daemon log files live;
;;   - byggsteg-managed-project-dir, the checkout path convention;
;;   - make-guile-server-shepherd-daemon, a factory that turns a
;;     project directory plus a command into a respawning Shepherd
;;     daemon with its own log file and a sane environment.
;;
;; The environment that factory hands a daemon is a fixed list, and one
;; of its entries is load-bearing for every translated page: LANG.  A
;; process started without a locale runs in the C locale, whose codeset
;; is ANSI_X3.4-1968, and GNU gettext converts a catalog's messages to
;; the codeset of the current LC_CTYPE.  Without LANG, then, every
;; Japanese (or Russian, or Greek) message is transliterated to "?"
;; before it ever reaches a page, even though the .mo files are UTF-8
;; and the response body is written as UTF-8.  The applications also
;; force a UTF-8 LC_CTYPE themselves (see their ENTRY files), but the
;; deployment should not rely on that.
;;
;; Code:

(define-module (wolk-jjba prelude)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 time)
  #:use-module (ice-9 format)
  #:use-module (ice-9 string-fun)
  #:use-module (ice-9 iconv)
  #:use-module (ice-9 threads)
  #:use-module (gnu services shepherd)
  #:export (byggsteg-managed-project-dir make-guile-server-shepherd-daemon
                                         wolk-jjba-log-directory syscall))

;; Directory holding the per-daemon log files produced through the
;; Shepherd `#:log-file' constructor argument.  It is kept separate
;; from the system log files so that each service has one dedicated,
;; ordered stream that never gets mixed into /var/log/messages.
(define wolk-jjba-log-directory
  "/var/log/wolk-jjba")

(define* (byggsteg-managed-project-dir dir
                                       #:key (branch 'trunk))
  (format #f "/etc/byggsteg/job-clone/~a/~a" dir branch))

(define* (make-guile-server-shepherd-daemon #:key service-name
                                            directory
                                            documentation
                                            provision
                                            (requirement '())
                                            (cmd '("make" "production-server"))
                                            (log-file #f)
                                            ;; Who the daemon runs as.  A
                                            ;; daemon that is given a #:user is
                                            ;; unprivileged from its first
                                            ;; instruction, so it can only
                                            ;; write below directories that
                                            ;; user owns.  The applications
                                            ;; here run as root because they
                                            ;; build in the Guix store, but a
                                            ;; daemon that only *uses* the
                                            ;; machine (rather than
                                            ;; provisioning it) should name a
                                            ;; user.
                                            (user #f)
                                            (group #f)
                                            ;; When a #:group is passed,
                                            ;; Shepherd calls setgroups with
                                            ;; exactly this list: the daemon
                                            ;; keeps no supplementary group of
                                            ;; its parent, so everything it is
                                            ;; allowed to use beyond its
                                            ;; primary group has to be named
                                            ;; here.
                                            (supplementary-groups '())
                                            ;; A daemon that shares a directory
                                            ;; with another account needs a
                                            ;; umask that lets the other one
                                            ;; write: #o002 makes everything it
                                            ;; creates group-writable.
                                            (file-creation-mask #f)
                                            ;; Names added to the daemon's
                                            ;; environment after the fixed list
                                            ;; below.  This is where a
                                            ;; deployment says how its daemon
                                            ;; should build: the variables
                                            ;; (byggsteg container) reads are
                                            ;; named here, not in the daemon's
                                            ;; source.
                                            (extra-env '())
                                            (env '("LANG=en_US.utf8"
                                                   "GUILE_LOAD_PATH=/run/current-system/profile/share/guile/site/3.0"
                                                   "GUILE_DBD_PATH=/run/current-system/profile/lib"
                                                   "C_INCLUDE_PATH=/run/current-system/profile/include"
                                                   "GUILE_LOAD_COMPILED_PATH=/run/current-system/profile/lib/guile/3.0/site-ccache:/run/current-system/profile/share/guile/site/3.0"
                                                   "LIBRARY_PATH=/run/current-system/profile/lib"
                                                   "SSL_CERT_DIR=/etc/ssl/certs"
                                                   "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
                                                   "GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt"
                                                   "GIT_SSL_NO_VERIFY=1"
                                                   "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin")))
  ;; Every daemon logs its stdout/stderr to its own file instead of
  ;; sharing the system log.  Shepherd is PID 1, so it creates the log
  ;; file (as root) before dropping privileges: only the directory
  ;; itself has to exist.
  (define resolved-log-file
    (or log-file
        (format #f "~a/~a.log" wolk-jjba-log-directory service-name)))
  (define (service-shepherd-daemon config)
    (list (shepherd-service (documentation documentation)
                            (provision provision)
                            (requirement requirement)
                            (start #~(lambda args
                                       (mkdir-p #$wolk-jjba-log-directory)
                                       ((make-forkexec-constructor (list #$@cmd)
                                                                   #:directory #$directory
                                                                   #:user #$user
                                                                   #:group #$group
                                                                   #:supplementary-groups
                                                                   '#$supplementary-groups
                                                                   #:file-creation-mask
                                                                   #$file-creation-mask
                                                                   #:log-file #$resolved-log-file
                                                                   #:environment-variables
                                                                   (list #$@env
                                                                         #$@extra-env))
                                        args)))
                            (stop #~(make-kill-destructor))
                            (auto-start? #t)
                            (respawn? #t))))

  (service (service-type (name service-name)
                         (description documentation)
                         (default-value '())
                         (extensions (list (service-extension
                                            shepherd-root-service-type
                                            service-shepherd-daemon))))))

(define (syscall cmd)
  (let* ((process (open-input-pipe cmd))
         (process-output (get-string-all process)))
    (close-pipe process)
    (display process-output) process-output))
