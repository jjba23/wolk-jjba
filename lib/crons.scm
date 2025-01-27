;;;; wolk-jjba

;; Copyright (C) 2024 Josep Jesus Bigorra Algaba

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

(define-module (wolk-jjba crons)
  #:use-module (gnu)
  #:use-module (guix))

(use-service-modules mcron)

(define* (make-backups-job #:key pwd dest-dir name includes)
  (string-join `(,(format #f "mkdir -p ~a" dest-dir) ,(format #f "cd ~a" pwd)
                 ,(format #f "BACKUP_NAME=\"~a-$(date +%s).tar.gz\"" name)
                 ,(format #f "tar -czvf \"./$BACKUP_NAME\" ~a"
                          (string-join includes " "))
                 ,(format #f "mv ./$BACKUP_NAME ~a/" dest-dir)) " && "))

(define-public wikimusic-make-backups-job
  `(job "0 */12 * * *"
        ,(make-backups-job #:dest-dir "/wolk-jjba-backups/wikimusic"
                           #:pwd "/srv/wikimusic"
                           #:name "wikimusic-backup"
                           #:includes '("db.sqlite"))))

(define-public minecraft-make-backups-job
  `(job "0 */12 * * *"
        ,(make-backups-job #:dest-dir "/wolk-jjba-backups/minecraft"
                           #:pwd "/srv/games"
                           #:name "minecraft-backup"
                           #:includes '("minecraft"))))

(define-public byggsteg-make-backups-job
  `(job "0 */12 * * *"
        ,(make-backups-job #:dest-dir "/wolk-jjba-backups/byggsteg"
                           #:pwd "/etc/byggsteg/job-clone/byggsteg/trunk"
                           #:name "byggsteg-backup"
                           #:includes '("byggsteg.db" "byggsteg.db-shm"
                                        "byggsteg.db-wal"))))

(define-public lucidplan-make-backups-job
  `(job "0 */12 * * *"
        ,(make-backups-job #:dest-dir "/wolk-jjba-backups/lucidplan"
                           #:pwd "/etc/lucidplan/job-clone/lucidplan/trunk"
                           #:name "lucidplan-backup"
                           #:includes '("lucidplan.db" "lucidplan.db-shm"
                                        "lucidplan.db-wal"))))

(define-public wolk-jjba-cron-jobs-service
  (simple-service 'wolk-jjba-cron-jobs mcron-service-type
                  (list wikimusic-make-backups-job minecraft-make-backups-job
                        byggsteg-make-backups-job
                        lucidplan-make-backups-job)))
