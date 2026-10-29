;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (wolk-jjba jobs).  The backup scripts are strings, so
;; they are compared as strings; the timers are Shepherd services, so
;; they are read through the service type's extension the way the service
;; compiler reads them.  What is checked is what has bitten before: an
;; archive name that is not unique, a pruning command that deletes one
;; file too many, a backup of a live SQLite database, a timer with no log
;; file, and a job that never gets a chance to run because it is not in
;; the list.

;;; Code:

(define-module (veritas unit jobs-spec)
  #:use-module (veritas veritas)
  #:use-module (guix)
  #:use-module (guix gexp)
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

(define (start-of name)
  "The start gexp of the timer NAME, as text.

`gexp->approximate-sexp' rather than printing the gexp itself: newer
Guix releases print a gexp as `#<gexp file:line>' without its content,
so an assertion that looks for the schedule in a printed gexp would
pass on one Guix version and fail on the next."
  (object->string (gexp->approximate-sexp
                   (shepherd-service-start (timer-named name)))))

(define wikimusic-backup (timer-named 'backup-wikimusic))
(define minecraft-prune (timer-named 'prune-minecraft))
(define postgres-backup (timer-named 'backup-postgres))
(define upload (timer-named 'backup-upload))

(define sample-db-backup
  (make-backups-job #:pwd "/etc/byggsteg/job-clone/probe/trunk"
                    #:dest-dir "/wolk-jjba-backups/probe"
                    #:name "probe-backup"
                    #:sqlite-dbs '("probe.db")))

(define sample-tree-backup
  (make-backups-job #:pwd "/srv"
                    #:dest-dir "/wolk-jjba-backups/sites"
                    #:name "sites-backup"
                    #:includes '("http")))

(define sample-dump-backup
  (make-dump-backups-job #:dest-dir "/wolk-jjba-backups/probe"
                         #:name "probe-backup"
                         #:command "pg_dumpall --clean"
                         #:suffix "sql.gz"))

(define jobs-suite
  (suite "Jobs Suite"

         (test "A database backup is one transaction"
               (assert-true (contains? sample-db-backup "set -euo pipefail")
                            #:name "A failing step fails the job")
               (assert-true (contains? sample-db-backup
                                              "cd /etc/byggsteg/job-clone/probe/trunk")
                            #:name "The archive is made in the project directory")
               (assert-true (contains? sample-db-backup
                                              "ARCHIVE=\"probe-backup-$(date +%s).tar.gz\"")
                            #:name "The archive name carries a timestamp")
               (assert-true (contains? sample-db-backup "trap")
                            #:name "A trap removes the plaintext and partial files")
               (assert-true (contains? sample-db-backup "\"./$ARCHIVE\"")
                            #:name "The trap names the archive it cleans up")
               (assert-true (contains? sample-db-backup
                                              "openssl enc -aes-256-cbc -salt -pbkdf2")
                            #:name "The archive is encrypted on the way out")
               (assert-true (contains? sample-db-backup
                                              "-pass file:\"$HOME/.backup-password\"")
                            #:name "The passphrase is read from a file, not the script")
               (assert-true (contains? sample-db-backup ".enc.part")
                            #:name "The ciphertext is staged and renamed into place")
               (assert-true (contains? sample-db-backup
                                              "sha256sum -- \"./$ARCHIVE.enc\"")
                            #:name "A checksum sidecar is written next to the archive")
               (assert-true (contains? sample-db-backup
                                              (string-append
                                               "mv \"./$ARCHIVE.enc\" \"./$ARCHIVE.enc.sha256\" "
                                               "/wolk-jjba-backups/probe/"))
                            #:name "The archive and its checksum are moved into place")
               (assert-true (contains? sample-db-backup
                                              "mkdir -p /wolk-jjba-backups/probe")
                            #:name "The destination is created if missing"))

         (test "A database backup snapshots instead of copying live files"
               (assert-true (contains? sample-db-backup "\".backup probe.db\"")
                            #:name "The database is snapshotted with sqlite3 .backup")
               (assert-true (contains? sample-db-backup "PRAGMA quick_check")
                            #:name "The snapshot is checked before it is stored")
               (assert-true (contains? sample-db-backup
                                              "tar -czf \"./$ARCHIVE\" -C \"$WORK\" probe.db")
                            #:name "The archive holds the snapshot, not the live file")
               (assert-true (not (contains? sample-db-backup "probe.db-wal"))
                            #:name "The -wal and -shm files are no longer tarred"))

         (test "A file backup still tars what it is given"
               (assert-true (contains? sample-tree-backup
                                              "tar -czf \"./$ARCHIVE\" http")
                            #:name "The include is tarred as it is")
               (assert-true (not (contains? sample-tree-backup ".backup "))
                            #:name "No database is snapshotted for a file backup"))

         (test "A dump backup refuses an empty dump"
               (assert-true (contains? sample-dump-backup
                                              "pg_dumpall --clean > \"$WORK/$ARCHIVE\"")
                            #:name "The command writes the archive")
               (assert-true (contains? sample-dump-backup "test -s")
                            #:name "An empty dump fails the job instead of being stored")
               (assert-true (contains? sample-dump-backup
                                              "ARCHIVE=\"probe-backup-$(date +%s).sql.gz\"")
                            #:name "The dump keeps its own extension"))

         (test "Pruning deletes exactly the archives it should"
               (assert-true (contains? (clean-backups-job #:pwd "/wolk-jjba-backups/probe"
                                                          #:keep-amount 3)
                                       "find . -maxdepth 1 -type f -name '*.enc'")
                            #:name "Only regular files matching the archive pattern")
               (assert-true (contains? (clean-backups-job #:pwd "/p" #:keep-amount 3)
                                       "tail -n +4")
                            #:name "Keeping three means dropping from the fourth")
               (assert-true (contains? (clean-backups-job #:pwd "/p" #:keep-amount 1)
                                       "tail -n +2")
                            #:name "Keeping one means dropping from the second")
               (assert-true (contains? (clean-backups-job #:pwd "/p" #:keep-amount 3)
                                       "rm -v -- \"$archive\" \"$archive.sha256\"")
                            #:name "The checksum goes with its archive")
               (assert-true (not (contains? (clean-backups-job #:pwd "/p"
                                                               #:keep-amount 3)
                                            "xargs"))
                            #:name "The prune no longer deletes whatever sorts last")
               (assert-true (contains? (clean-backups-job #:pwd "/p" #:keep-amount 3)
                                       "-mtime +1 -print -delete")
                            #:name "Leftovers of an interrupted run are removed later"))

         (test "Pruning can also bound an archive by age"
               (assert-true (contains? (clean-backups-job #:pwd "/p"
                                                          #:keep-amount 6
                                                          #:keep-days 45)
                                       "-mtime +45")
                            #:name "An archive older than the age limit goes")
               (assert-true (not (contains? (clean-backups-job #:pwd "/p"
                                                               #:keep-amount 6)
                                            "-mtime +45"))
                            #:name "No age limit means count only"))

         (test "Every job is a timer with a log and a trigger"
               (assert-equal #:expect 18
                             #:got (length timers)
                             #:name "Eighteen jobs are scheduled")
               (assert-equal #:expect 18
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
               (assert-true (contains? (start-of 'backup-wikimusic)
                                       "/var/log/wolk-jjba/backup-wikimusic.log")
                            #:name "The backup log is named after the job")
               (assert-equal #:expect 18
                             #:got (length rotated-logs)
                             #:name "Every job log is registered for rotation")
               (assert-true (and (member "/var/log/wolk-jjba/backup-upload.log"
                                         rotated-logs)
                                 #t)
                            #:name "The Storage Box mirror log is rotated too")
               (assert-true (and (member "/var/log/wolk-jjba/backup-postgres.log"
                                         rotated-logs)
                                 #t)
                            #:name "The PostgreSQL dump log is rotated too"))

         (test "The schedules are the ones the README documents"
               (assert-true (contains? (start-of 'backup-wikimusic)
                                       "0 */12 * * *")
                            #:name "wikimusic is archived twice a day")
               (assert-true (contains? (start-of 'prune-minecraft)
                                       "0 * * * *")
                            #:name "Minecraft is pruned hourly")
               (assert-true (contains? (start-of 'backup-postgres)
                                       "30 */12 * * *")
                            #:name "PostgreSQL is dumped twice a day")
               (assert-true (contains? (start-of 'backup-upload)
                                       "58 * * * *")
                            #:name "The mirror runs just before the hour"))

         (test "PostgreSQL is dumped, not tarred, and as the postgres role"
               (assert-true (contains? (start-of 'backup-postgres)
                                       "pg_dumpall --clean --if-exists")
                            #:name "The dump is restorable into a live cluster")
               (assert-true (contains? (start-of 'backup-postgres)
                                       "sudo -u postgres")
                            #:name "peer authentication is satisfied by running as postgres"))

         (test "The mirror is a delete-mirror run as an unprivileged user"
               (assert-true (contains? (start-of 'backup-upload)
                                       "rsync -av --delete")
                            #:name "Deleted backups disappear from the Storage Box")
               (assert-true (contains? (start-of 'backup-upload)
                                       "wolkenschlosslagerung")
                            #:name "The Storage Box is the destination")
               (assert-true (contains? (start-of 'backup-upload) "backer-upper")
                            #:name "The mirror does not run as root")
               (assert-true (contains? (start-of 'backup-upload)
                                       "--exclude '/archive'")
                            #:name "The long-term archive is not mirrored over"))

         (test "Applications are restarted hourly"
               (assert-true (contains? (start-of 'restart-app-daemons)
                                       "herd restart lucidplan-daemon")
                            #:name "lucidplan is restarted by the timer")
               (assert-true (contains? (start-of 'restart-app-daemons)
                                       "herd restart byggsteg-daemon")
                            #:name "byggsteg is restarted by the timer")
               (assert-true (contains? (start-of 'restart-app-daemons)
                                       "herd restart torikomi-daemon")
                            #:name "torikomi is restarted by the timer")
               (assert-true (contains? (start-of 'restart-app-daemons)
                                       "herd restart symbanta-api-daemon")
                            #:name "symbanta is restarted by the timer"))

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
