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

(define-public wikimusic-make-backups-job
  `(job "0 * * * *"
        ,(string-join `("mkdir -p /wolk-jjba-backups/wikimusic"
                        "cd /srv/wikimusic"
                        "BACKUP_NAME=\"minecraft-backup-$(date +%s).tar.gz\""
                        "tar -czvf \"./$BACKUP_NAME\" db.sqlite"
                        "mv ./$BACKUP_NAME /wolk-jjba-backups/wikimusic/")
                      " && ")))

(define-public minecraft-make-backups-job
  `(job "0 0 * * *"
        ,(string-join `("mkdir -p /wolk-jjba-backups/minecraft"
                        "cd /srv/games/minecraft"
                        "BACKUP_NAME=\"minecraft-backup-$(date +%s).tar.gz\""
                        "tar -czvf \"./$BACKUP_NAME\" Minecraft"
                        "mv ./$BACKUP_NAME /wolk-jjba-backups/minecraft/")
                      " && ")))

(define-public wolk-jjba-cron-jobs-service
  (simple-service 'wolk-jjba-cron-jobs mcron-service-type
                  (list wikimusic-make-backups-job minecraft-make-backups-job)))
