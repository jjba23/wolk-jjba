;;;; wolk-jjba

;; Copyright (C) 2025 - Josep Bigorra, jjba23 <jjbigorra@gmail.com>

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

;;
;; Commentary:
;;
;; Define cron jobs for the wolk-jjba instance
;; a useful tip is to remember to reboot the machine,
;; or do a `sudo herd restart mcron'

(define-module (wolk-jjba crons)
  #:use-module (gnu)
  #:use-module (guix))

(use-service-modules mcron)

;; ====== Abstractions ======

(define* (make-backups-job #:key pwd dest-dir name includes)
  (string-join `(,(format #f "mkdir -p ~a" dest-dir) ,(format #f "cd ~a" pwd)
                 ,(format #f "BACKUP_NAME=\"~a-$(date +%s).tar.gz\"" name)
                 ,(format #f "tar -czvf \"./$BACKUP_NAME\" ~a"
                          (string-join includes " "))
                 ,(format #f "mv ./$BACKUP_NAME ~a/" dest-dir)) " && "))

(define* (clean-backups-job #:key pwd keep-amount)
  (format #f "cd ~a && ls -A1t | tail -n +~a | xargs rm -v"
          pwd
          (+ 1 keep-amount)))

;; ====== Wikimusic ======

;; backup wikimusic at 00:00 and 12:00
(define-public wikimusic-make-backups-job
  `(job "0 */12 * * *"
        ,(make-backups-job #:dest-dir "/wolk-jjba-backups/wikimusic"
                           #:pwd "/etc/byggsteg/job-clone/wikimusic/trunk"
                           #:name "wikimusic-backup"
                           #:includes '("wikimusic.db" "wikimusic.db-shm"
                                        "wikimusic.db-wal"))))

;; clean backups wikimusic at 00:15 and 12:15
(define-public wikimusic-clean-backups-job
  `(job "15 */12 * * *"
        ,(clean-backups-job #:pwd "/wolk-jjba-backups/wikimusic"
                            #:keep-amount 6)))

;; ====== Minecraft Server ======

;; backup minecraft at At 5:00 on Sunday, Tuesday, and Thursday
(define-public minecraft-make-backups-job
  `(job "0 5 * * 0,2,4"
        ,(make-backups-job #:dest-dir "/wolk-jjba-backups/minecraft"
                           #:pwd "/srv/games"
                           #:name "minecraft-backup"
                           #:includes '("minecraft"))))

;; clean backups minecraft at At 6:00 on Sunday, Tuesday, and Thursday
(define-public minecraft-clean-backups-job
  `(job "0 6 * * 0,2,4"
        ,(clean-backups-job #:pwd "/wolk-jjba-backups/minecraft"
                            #:keep-amount 3)))

;; ====== Byggsteg ======

;; backup byggsteg at 00:45 and 12:45
(define-public byggsteg-make-backups-job
  `(job "45 */12 * * *"
        ,(make-backups-job #:dest-dir "/wolk-jjba-backups/byggsteg"
                           #:pwd "/etc/byggsteg/job-clone/byggsteg/trunk"
                           #:name "byggsteg-backup"
                           #:includes '("byggsteg.db" "byggsteg.db-shm"
                                        "byggsteg.db-wal"))))

;; clean backups byggsteg at 00:50 and 12:50
(define-public byggsteg-clean-backups-job
  `(job "50 */12 * * *"
        ,(clean-backups-job #:pwd "/wolk-jjba-backups/byggsteg"
                            #:keep-amount 6)))

;; ====== Static Sites ======

;; backup static sites at 00:00 and 12:00
(define-public static-sites-make-backups-job
  `(job "0 */12 * * *"
        ,(make-backups-job #:dest-dir "/wolk-jjba-backups/static-sites"
                           #:pwd "/srv"
                           #:name "static-sites-backup"
                           #:includes '("http"))))

;; clean backups static sites at 00:10 and 12:10
(define-public static-sites-clean-backups-job
  `(job "10 */12 * * *"
        ,(clean-backups-job #:pwd "/wolk-jjba-backups/static-sites"
                            #:keep-amount 6)))

;; ====== LucidPlan ======

;; backup lucidplan every at 00:15 and 12:15
(define-public lucidplan-make-backups-job
  `(job "15 */12 * * *"
        ,(make-backups-job #:dest-dir "/wolk-jjba-backups/lucidplan"
                           #:pwd "/etc/byggsteg/job-clone/lucidplan/trunk"
                           #:name "lucidplan-backup"
                           #:includes '("lucidplan.db" "lucidplan.db-shm"
                                        "lucidplan.db-wal"))))

;; clean backups lucidplan at 00:25 and 12:25
(define-public lucidplan-clean-backups-job
  `(job "25 */12 * * *"
        ,(clean-backups-job #:pwd "/wolk-jjba-backups/lucidplan"
                            #:keep-amount 6)))

;; ====== Cloud storage ======

;; sync backups to s3 every 3 hours at :30m
(define-public wolk-jjba-upload-backups-job
  #~(job "30 */3 * * *"
         "PATH=\"$HOME/.nix-profile/bin:$PATH\" aws s3 sync /wolk-jjba-backups s3://wolk-jjba-backups"
         #:user "backer-upper"))

;; ====== Restart services periodically ======
(define-public wolk-jjba-restart-services-job
  #~(job "0 * * * *"
         "herd restart byggsteg && herd restart lucidplan && herd restart wikimusic && herd restart oculuslambda"))

(define-public wolk-jjba-cron-jobs-service
  (simple-service 'wolk-jjba-cron-jobs mcron-service-type
                  (list ;wikimusic
                   wikimusic-make-backups-job
                   wikimusic-clean-backups-job
                   ;; minecraft
                   minecraft-make-backups-job
                   minecraft-clean-backups-job
                   ;; byggsteg
                   byggsteg-make-backups-job
                   byggsteg-clean-backups-job
                   ;; static sites
                   static-sites-make-backups-job
                   static-sites-clean-backups-job
                   ;; lucidplan
                   lucidplan-make-backups-job
                   lucidplan-clean-backups-job
                   ;; cloud
                   wolk-jjba-upload-backups-job
                   ;; restarts
                   wolk-jjba-restart-services-job)))
