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
  '(job "0 * * * *"
    "cd /srv/wikimusic && tar -czvf \"./backups/wikimusic-$(date +%s).tar.gz\" db.sqlite"))

(define-public minecraft-make-backups-job
  '(job "0 0 * * *"
    "cd /root/Spelletjes && tar -czvf \"./minecraft-backups/minecraft-backup-$(date +%s).tar.gz\" Minecraft"))

(define-public wolk-jjba-cron-jobs-service
  (simple-service 'wolk-jjba-cron-jobs mcron-service-type
                  (list wikimusic-make-backups-job minecraft-make-backups-job)))
