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
;; Shepherd timer jobs for wolk-jjba: backup creation, local pruning,
;; the Hetzner Storage Box mirror and application restarts.  The weekly
;; auto-upgrade remains an mcron job at the bottom of this file, because
;; it reconfigures the system and reboots; running that from a Shepherd
;; timer would risk the reconfigure stopping the timer that launched it.
;;
;; Backups are created twice a day for most projects (Minecraft three
;; times a week), pruned hourly, and mirrored to the Storage Box hourly.
;; Pruning uses `xargs -r', so an empty backup directory is a no-op
;; instead of a failing rm.
;;
;; Inspect and trigger jobs with:
;;
;;   sudo herd status backup-wikimusic
;;   sudo herd trigger backup-wikimusic
;;   sudo herd status backup-upload
;;   sudo herd trigger backup-upload
;;
;; The timer logs are under /var/log/wolk-jjba/<job>.log and are
;; registered with the Shepherd log rotation service.
;;
;; Code:

(define-module (wolk-jjba jobs)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services mcron)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages bash)
  #:use-module (ice-9 format)
  #:export (shepherd-jobs-capability
            auto-upgrade-capability
            make-backups-job
            clean-backups-job))

;; ====== Shell command builders ======

(define* (make-backups-job #:key pwd dest-dir name includes)
  (string-join (list (format #f "mkdir -p ~a" dest-dir)
                     (format #f "cd ~a" pwd)
                     (format #f "BACKUP_NAME=\"~a-$(date +%s).tar.gz\"" name)
                     (format #f "tar -czvf \"./$BACKUP_NAME\" ~a"
                             (string-join includes " "))
                     (format #f
                      "openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in ./$BACKUP_NAME -out ./$BACKUP_NAME.enc -pass file:$HOME/.backup-password")
                     (format #f "mv ./$BACKUP_NAME.enc ~a/" dest-dir)
                     (format #f "rm ./$BACKUP_NAME")) " && "))

(define* (clean-backups-job #:key pwd keep-amount)
  (format #f "cd ~a && ls -A1t | tail -n +~a | xargs -r rm -v" pwd
          (+ 1 keep-amount)))

;; ====== Timer service factory ======

(define* (timer-service #:key
                        name
                        schedule
                        script
                        (user "root")
                        (group "root")
                        (home "/root")
                        (requirement '(user-processes file-systems))
                        (max-duration 14400)
                        documentation)
  "Return a Shepherd service running SCRIPT according to SCHEDULE.

SCHEDULE is a Vixie cron string.  SCRIPT is executed with bash as USER
and GROUP, with HOME set to HOME, and with the output written to
/var/log/wolk-jjba/NAME.log.  The service has a `trigger' action, so it
can be run immediately with `herd trigger NAME'."
  (let ((log-file (format #f "/var/log/wolk-jjba/~a.log" name)))
    (shepherd-service
     (provision (list name))
     (requirement requirement)
     (documentation documentation)
     (modules '((shepherd service timer)))
     (start #~(make-timer-constructor
                (cron-string->calendar-event #$schedule)
                (command (list #$(file-append bash-minimal "/bin/bash")
                               "-c"
                               #$script)
                         #:user #$user
                         #:group #$group
                         #:environment-variables
                         (list (string-append "HOME=" #$home)
                               "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin"
                               "SSL_CERT_DIR=/etc/ssl/certs"
                               "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"))
                #:log-file #$log-file
                #:wait-for-termination? #t
                #:max-duration #$max-duration))
     (stop #~(make-timer-destructor))
     (respawn? #t)
     (actions (list (shepherd-action
                     (inherit shepherd-trigger-action)
                     (documentation
                      "Run this job now, without waiting for its timer.")))))))

(define* (make-backup-service #:key
                              service-name
                              schedule
                              pwd
                              dest-dir
                              archive-name
                              includes)
  (timer-service
   #:name service-name
   #:schedule schedule
   #:script (make-backups-job #:pwd pwd
                              #:dest-dir dest-dir
                              #:name archive-name
                              #:includes includes)
   #:documentation (format #f "Create the ~a archive." archive-name)))

(define* (prune-backup-service #:key service-name schedule pwd keep-amount)
  (timer-service
   #:name service-name
   #:schedule schedule
   #:script (clean-backups-job #:pwd pwd #:keep-amount keep-amount)
   #:documentation (format #f "Prune old backups in ~a." pwd)))

;; ====== Backup and prune services ======

;; Wikimusic

(define wikimusic-backup-service
  (make-backup-service
   #:service-name 'backup-wikimusic
   #:schedule "0 */12 * * *"
   #:pwd "/etc/byggsteg/job-clone/wikimusic/trunk"
   #:dest-dir "/wolk-jjba-backups/wikimusic"
   #:archive-name "wikimusic-backup"
   #:includes '("wikimusic.db" "wikimusic.db-shm" "wikimusic.db-wal")))

(define wikimusic-prune-service
  (prune-backup-service
   #:service-name 'prune-wikimusic
   #:schedule "15 * * * *"
   #:pwd "/wolk-jjba-backups/wikimusic"
   #:keep-amount 6))

;; Minecraft

(define minecraft-backup-service
  (make-backup-service
   #:service-name 'backup-minecraft
   #:schedule "0 5 * * 0,2,4"
   #:pwd "/srv/games"
   #:dest-dir "/wolk-jjba-backups/minecraft"
   #:archive-name "minecraft-backup"
   #:includes '("minecraft")))

(define minecraft-prune-service
  (prune-backup-service
   #:service-name 'prune-minecraft
   #:schedule "0 * * * *"
   #:pwd "/wolk-jjba-backups/minecraft"
   #:keep-amount 3))

;; Byggsteg

(define byggsteg-backup-service
  (make-backup-service
   #:service-name 'backup-byggsteg
   #:schedule "45 */12 * * *"
   #:pwd "/etc/byggsteg/job-clone/byggsteg/trunk"
   #:dest-dir "/wolk-jjba-backups/byggsteg"
   #:archive-name "byggsteg-backup"
   #:includes '("byggsteg.db" "byggsteg.db-shm" "byggsteg.db-wal")))

(define byggsteg-prune-service
  (prune-backup-service
   #:service-name 'prune-byggsteg
   #:schedule "50 * * * *"
   #:pwd "/wolk-jjba-backups/byggsteg"
   #:keep-amount 6))

;; Static sites

(define static-sites-backup-service
  (make-backup-service
   #:service-name 'backup-static-sites
   #:schedule "0 */12 * * *"
   #:pwd "/srv"
   #:dest-dir "/wolk-jjba-backups/static-sites"
   #:archive-name "static-sites-backup"
   #:includes '("http")))

(define static-sites-prune-service
  (prune-backup-service
   #:service-name 'prune-static-sites
   #:schedule "10 * * * *"
   #:pwd "/wolk-jjba-backups/static-sites"
   #:keep-amount 6))

;; LucidPlan

(define lucidplan-backup-service
  (make-backup-service
   #:service-name 'backup-lucidplan
   #:schedule "15 */12 * * *"
   #:pwd "/etc/byggsteg/job-clone/lucidplan/trunk"
   #:dest-dir "/wolk-jjba-backups/lucidplan"
   #:archive-name "lucidplan-backup"
   #:includes '("lucidplan.db" "lucidplan.db-shm" "lucidplan.db-wal")))

(define lucidplan-prune-service
  (prune-backup-service
   #:service-name 'prune-lucidplan
   #:schedule "25 * * * *"
   #:pwd "/wolk-jjba-backups/lucidplan"
   #:keep-amount 6))

;; Torikomi

(define torikomi-backup-service
  (make-backup-service
   #:service-name 'backup-torikomi
   #:schedule "0 */12 * * *"
   #:pwd "/srv"
   #:dest-dir "/wolk-jjba-backups/torikomi"
   #:archive-name "torikomi-backup"
   #:includes '("torikomi")))

(define torikomi-prune-service
  (prune-backup-service
   #:service-name 'prune-torikomi
   #:schedule "30 * * * *"
   #:pwd "/wolk-jjba-backups/torikomi"
   #:keep-amount 6))

;; PingWing

(define pingwing-backup-service
  (make-backup-service
   #:service-name 'backup-pingwing
   #:schedule "45 */12 * * *"
   #:pwd "/etc/byggsteg/job-clone/pingwing/trunk"
   #:dest-dir "/wolk-jjba-backups/pingwing"
   #:archive-name "pingwing-backup"
   #:includes '("pingwing.db" "pingwing.db-shm" "pingwing.db-wal")))

(define pingwing-prune-service
  (prune-backup-service
   #:service-name 'prune-pingwing
   #:schedule "55 * * * *"
   #:pwd "/wolk-jjba-backups/pingwing"
   #:keep-amount 6))

;; ====== Hetzner Storage Box mirror ======

(define backup-upload-service
  (timer-service
   #:name 'backup-upload
   #:schedule "58 * * * *"
   #:script "rsync -av --delete --timeout=600 --contimeout=30 --exclude '/archive' /wolk-jjba-backups/ wolkenschlosslagerung:wolk-jjba-backups"
   #:user "backer-upper"
   #:group "users"
   #:home "/home/backer-upper"
   #:requirement '(user-processes file-systems networking)
   #:max-duration 14400
   #:documentation
   "Mirror /wolk-jjba-backups to the Hetzner Storage Box."))

;; ====== Application restarts ======

(define restart-app-daemons-service
  (timer-service
   #:name 'restart-app-daemons
   #:schedule "0 * * * *"
   #:script (string-join
             (map (lambda (daemon)
                    (format #f "herd restart ~a || true" daemon))
                  '(byggsteg-daemon lucidplan-daemon wikimusic-daemon
                                    pingwing-daemon))
             " && ")
   #:max-duration 300
   #:documentation "Restart the application Shepherd daemons."))

;; ====== Weekly upgrade (mcron) ======
;;
;; The upgrade job is deliberately left on mcron: it runs
;; `guix system reconfigure', and a Shepherd timer would risk being
;; stopped by the very reconfigure it launches.  mcron keeps it outside
;; the Shepherd service graph.

(define auto-upgrade-job
  #~(job "0 0 * * MON"
     "guix pull && cd /etc/byggsteg/job-clone/wolk-jjba/trunk && sudo git pull && sudo maak fr && sudo reboot"
     #:user "joe"))

(define (auto-upgrade-capability)
  (simple-service 'wolk-jjba-auto-upgrade mcron-service-type
                  (list auto-upgrade-job)))

;; ====== Service type ======

(define shepherd-job-names
  '(backup-wikimusic prune-wikimusic
    backup-minecraft prune-minecraft
    backup-byggsteg prune-byggsteg
    backup-static-sites prune-static-sites
    backup-lucidplan prune-lucidplan
    backup-torikomi prune-torikomi
    backup-pingwing prune-pingwing
    backup-upload
    restart-app-daemons))

(define shepherd-job-log-files
  (map (lambda (name)
         (format #f "/var/log/wolk-jjba/~a.log" name))
       shepherd-job-names))

(define (shepherd-job-services)
  (list wikimusic-backup-service
        wikimusic-prune-service
        minecraft-backup-service
        minecraft-prune-service
        byggsteg-backup-service
        byggsteg-prune-service
        static-sites-backup-service
        static-sites-prune-service
        lucidplan-backup-service
        lucidplan-prune-service
        torikomi-backup-service
        torikomi-prune-service
        pingwing-backup-service
        pingwing-prune-service
        backup-upload-service
        restart-app-daemons-service))

(define shepherd-jobs-service-type
  (service-type
   (name 'wolk-jjba-shepherd-jobs)
   (extensions
    (list (service-extension
           shepherd-root-service-type
           (lambda (_) (shepherd-job-services)))
          (service-extension
           activation-service-type
           (const #~(begin
                      (use-modules (guix build utils))
                      (mkdir-p "/var/log/wolk-jjba"))))
          (service-extension
           log-rotation-service-type
           (const shepherd-job-log-files))))
   (default-value '())
   (description
    "Run backup, mirror, restart and upgrade jobs as Shepherd timers.")))

(define (shepherd-jobs-capability)
  (service shepherd-jobs-service-type))
