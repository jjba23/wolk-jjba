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

;;; Commentary:
;;
;; Unit tests for (wolk-jjba jobs).  The backup scripts are strings, so
;; they are compared as strings; the timers are Shepherd services, so
;; they are read through the service type's extension the way the service
;; compiler reads them.  What is checked is what has bitten before: an
;; archive name that is not unique, a pruning command that deletes one
;; file too many, a timer with no log file, and a job that never gets a
;; chance to run because it is not in the list.

;;; Code:

(define-module (veritas unit jobs-spec)
  #:use-module (veritas veritas)
  #:use-module (guix)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services mcron)
  #:use-module (gnu services shepherd)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba jobs)
  #:export (spec))

(define (contains? haystack needle)
  "Return #t when NEEDLE occurs in HAYSTACK.

`string-contains' returns the index, and an assertion wants #t."
  (and (string-contains haystack needle) #t))

(define (tree-contains? tree needle)
  "Return #t when NEEDLE occurs anywhere in the nested list TREE."
  (cond
    ((null? tree) #f)
    ((pair? tree) (or (tree-contains? (car tree) needle)
                      (tree-contains? (cdr tree) needle)))
    ((vector? tree) (tree-contains? (vector->list tree) needle))
    ((equal? tree needle) #t)
    (else #f)))

(define jobs-service (shepherd-jobs-capability))

(define (extension-towards type)
  "Return the extension of the jobs service that targets TYPE."
  (find (lambda (extension)
          (eq? (service-extension-target extension) type))
        (service-type-extensions (service-kind jobs-service))))

(define timers ((service-extension-compute
                 (extension-towards shepherd-root-service-type))
                '()))

(define rotated-logs ((service-extension-compute
                       (extension-towards log-rotation-service-type))
                      '()))

(define timer-names (map (lambda (timer)
                           (car (shepherd-service-provision timer)))
                         timers))

(define (timer-named name)
  (find (lambda (timer)
          (eq? (car (shepherd-service-provision timer)) name))
        timers))

(define wikimusic-backup (timer-named 'backup-wikimusic))
(define minecraft-prune (timer-named 'prune-minecraft))
(define upload (timer-named 'backup-upload))

(define sample-backup
  (make-backups-job #:pwd "/etc/byggsteg/job-clone/probe/trunk"
                    #:dest-dir "/wolk-jjba-backups/probe"
                    #:name "probe-backup"
                    #:includes '("probe.db" "probe.db-wal")))

(define jobs-suite
  (suite "Jobs Suite"

         (test "A backup is one transaction"
               (assert-true (contains? sample-backup
                                              "cd /etc/byggsteg/job-clone/probe/trunk")
                            #:name "The archive is made in the project directory")
               (assert-true (contains? sample-backup "probe.db probe.db-wal")
                            #:name "Every include is tarred")
               (assert-true (contains? sample-backup
                                              "BACKUP_NAME=\"probe-backup-$(date +%s).tar.gz\"")
                            #:name "The archive name carries a timestamp")
               (assert-true (contains? sample-backup
                                              "openssl enc -aes-256-cbc -salt -pbkdf2")
                            #:name "The archive is encrypted on the way out")
               (assert-true (contains? sample-backup
                                              "-pass file:$HOME/.backup-password")
                            #:name "The passphrase is read from a file, not the script")
               (assert-true (contains? sample-backup
                                              "mv ./$BACKUP_NAME.enc /wolk-jjba-backups/probe/")
                            #:name "The encrypted archive is moved into place")
               (assert-true (contains? sample-backup "rm ./$BACKUP_NAME")
                            #:name "The plaintext archive is removed")
               (assert-true (contains? sample-backup "mkdir -p /wolk-jjba-backups/probe")
                            #:name "The destination is created if missing"))

         (test "Pruning keeps exactly the requested number of archives"
               (assert-equal #:expect
                             "cd /wolk-jjba-backups/probe && ls -A1t | tail -n +4 | xargs -r rm -v"
                             #:got
                             (clean-backups-job #:pwd "/wolk-jjba-backups/probe"
                                                #:keep-amount 3)
                             #:name "Keeping three means dropping from the fourth")
               (assert-true (contains?                              (clean-backups-job #:pwd "/p" #:keep-amount 1)
                             "tail -n +2")
                            #:name "Keeping one means dropping from the second")
               (assert-true (contains?                              (clean-backups-job #:pwd "/p" #:keep-amount 3)
                             "xargs -r rm")
                            #:name "An empty directory is a no-op, not an error"))

         (test "Every job is a timer with a log and a trigger"
               (assert-equal #:expect 16
                             #:got (length timers)
                             #:name "Sixteen jobs are scheduled")
               (assert-equal #:expect 16
                             #:got (length (delete-duplicates timer-names))
                             #:name "No job is scheduled twice")
               (assert-true (and (every (lambda (timer)
                                          (shepherd-service-respawn? timer))
                                        timers)
                                 #t)
                            #:name "Every timer is respawned")
               (assert-equal #:expect '(trigger)
                             #:got
                             (map shepherd-action-name
                                  ((@@ (gnu services shepherd)
                                      shepherd-service-actions)
                                   wikimusic-backup))
                             #:name "A job can be run by hand with herd trigger")
               (assert-true (and (member '(shepherd service timer)
                                         (shepherd-service-modules
                                          wikimusic-backup))
                                 #t)
                            #:name "The timers come from the Shepherd's timer module"))

         (test "Each job logs to its own file, which is rotated"
               (assert-true (and (contains?                                   (object->string
                                   (shepherd-service-start wikimusic-backup))
                                  "/var/log/wolk-jjba/backup-wikimusic.log")
                                 #t)
                            #:name "The backup log is named after the job")
               (assert-equal #:expect 16
                             #:got (length rotated-logs)
                             #:name "Every job log is registered for rotation")
               (assert-true (and (member "/var/log/wolk-jjba/backup-upload.log"
                                         rotated-logs)
                                 #t)
                            #:name "The Storage Box mirror log is rotated too"))

         (test "The schedules are the ones the README documents"
               (assert-true (and (contains?                                   (object->string
                                   (shepherd-service-start wikimusic-backup))
                                  "0 */12 * * *")
                                 #t)
                            #:name "wikimusic is archived twice a day")
               (assert-true (and (contains?                                   (object->string
                                   (shepherd-service-start minecraft-prune))
                                  "0 * * * *")
                                 #t)
                            #:name "Minecraft is pruned hourly")
               (assert-true (and (contains?                                   (object->string (shepherd-service-start upload))
                                  "58 * * * *")
                                 #t)
                            #:name "The mirror runs just before the hour"))

         (test "The mirror is a delete-mirror run as an unprivileged user"
               (assert-true (and (contains?                                   (object->string (shepherd-service-start upload))
                                  "rsync -av --delete")
                                 #t)
                            #:name "Deleted backups disappear from the Storage Box")
               (assert-true (and (contains?                                   (object->string (shepherd-service-start upload))
                                  "wolkenschlosslagerung")
                                 #t)
                            #:name "The Storage Box is the destination")
               (assert-true (and (contains?                                   (object->string (shepherd-service-start upload))
                                  "backer-upper")
                                 #t)
                            #:name "The mirror does not run as root"))

         (test "Applications are restarted hourly"
               (assert-true (and (contains?                                   (object->string
                                   (shepherd-service-start
                                    (timer-named 'restart-app-daemons)))
                                  "herd restart lucidplan-daemon")
                                 #t)
                            #:name "lucidplan is restarted by the timer")
               (assert-true (and (contains?                                   (object->string
                                   (shepherd-service-start
                                    (timer-named 'restart-app-daemons)))
                                  "herd restart byggsteg-daemon")
                                 #t)
                            #:name "byggsteg is restarted by the timer"))

         (test "The weekly upgrade stays outside the Shepherd"
               (assert-equal #:expect '(mcron)
                             #:got
                             (map (lambda (extension)
                                    (service-type-name
                                     (service-extension-target extension)))
                                  (service-type-extensions
                                   (service-kind (auto-upgrade-capability))))
                             #:name
                             "The reconfigure job extends mcron, not shepherd"))))

(define (spec)
  (veritas-run jobs-suite))
