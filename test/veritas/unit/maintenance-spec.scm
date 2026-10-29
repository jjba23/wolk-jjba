;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (wolk-jjba maintenance).
;;
;; Two things are worth testing in a module made of shell strings, and
;; they are two different things.  The first is that the jobs exist at
;; all: every one of them is scheduled, every one of them writes to a
;; log file that is rotated, and the service type is wired to the
;; Shepherd and to the activation that creates the metrics directory --
;; a job that is defined but never added to the service list is a job
;; that silently never runs.
;;
;; The second is the part of each script that would be dangerous to get
;; wrong, which is mostly about *not* touching things: the prune must
;; not delete a directory, the temp-file cleanup must not delete a
;; socket, podman must not delete volumes, and the Prometheus textfiles
;; must be written through a rename so a scrape never reads half a
;; line.

;;; Code:

(define-module (veritas unit maintenance-spec)
  #:use-module (veritas veritas)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services shepherd)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba maintenance)
  #:export (spec))

(define (contains? haystack needle)
  "Return #t when NEEDLE occurs in HAYSTACK."
  (and (string-contains haystack needle) #t))

(define capability (maintenance-capability))

(define (extension-towards type)
  "Return the extension of the maintenance service that targets TYPE."
  (find (lambda (extension)
          (eq? (service-extension-target extension) type))
        (service-type-extensions (service-kind capability))))

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
  "Return the timer service provisioned as NAME."
  (find (lambda (timer)
          (eq? (car (shepherd-service-provision timer)) name))
        timers))

(define disk-report (disk-report-job))
(define guix-gc (guix-gc-job))
(define verify-backups (verify-backups-job))
(define podman-prune (podman-prune-job))
(define cache-clean (cache-clean-job))
(define tmp-clean (tmp-clean-job))
(define events-retention (symbanta-events-retention-job))

(define maintenance-suite
  (suite "Maintenance Suite"

         (test "Every maintenance job is scheduled exactly once"
               (assert-equal #:expect '(disk-report guix-gc nix-gc
                                                     verify-backups gfs-backup
                                                     podman-prune cache-clean
                                                     tmp-clean
                                                     prune-symbanta-events)
                             #:got timer-names
                             #:name "The nine jobs are the documented ones")
               (assert-equal #:expect 9
                             #:got (length (delete-duplicates timer-names))
                             #:name "No job is scheduled twice")
               (assert-true (and (every shepherd-service-respawn?
                                         timers)
                                 #t)
                            #:name "Every job is respawned"))

         (test "Every job logs to a rotated file"
               (assert-equal #:expect
                             '("/var/log/wolk-jjba/disk-report.log"
                               "/var/log/wolk-jjba/guix-gc.log"
                               "/var/log/wolk-jjba/nix-gc.log"
                               "/var/log/wolk-jjba/verify-backups.log"
                               "/var/log/wolk-jjba/gfs-backup.log"
                               "/var/log/wolk-jjba/podman-prune.log"
                               "/var/log/wolk-jjba/cache-clean.log"
                               "/var/log/wolk-jjba/tmp-clean.log"
                               "/var/log/wolk-jjba/prune-symbanta-events.log")
                             #:got rotated-logs
                             #:name "The log files are registered for rotation")
               (assert-true (and (member "/var/log/wolk-jjba/guix-gc.log"
                                         rotated-logs)
                                 #t)
                            #:name "The garbage collection log is kept"))

         (test "The long-term retention job runs the Scheme program, unprivileged"
               (let* ((service (timer-named 'gfs-backup))
                      (start (object->string
                              (gexp->approximate-sexp
                               (shepherd-service-start service)))))
                 (assert-true (contains? start "45 2 * * *")
                              #:name "It runs every night at 02:45")
                 (assert-true (contains? start "#<<program-file>")
                              #:name "It runs the gfs-backup program, not a shell script")
                 (assert-true (contains? start "backer-upper")
                              #:name "It runs as the user that owns the Storage Box key")
                 (assert-true (contains? start "HOME=/home/backer-upper")
                              #:name "With that user's HOME, so ssh finds the alias")
                 (assert-true (not (contains? start "bash"))
                              #:name "No shell is involved")))

         (test "The disk report publishes the long-term retention state"
               (assert-true (contains? disk-report
                                       "wolk_gfs_last_success_timestamp_seconds")
                            #:name "The last successful GFS run is a metric")
               (assert-true (contains? disk-report "wolk_archive_backups{project=")
                            #:name "And so is the archive count per project")
               (assert-true (contains? disk-report "/var/lib/wolk-gfs/last-success")
                            #:name "It reads the marker the job leaves behind"))

         (test "The service creates the metrics directory it writes into"
               (assert-true (and (extension-towards activation-service-type) #t)
                            #:name "There is an activation extension")
               (assert-true (contains? (object->string
                                        ((service-extension-compute
                                          (extension-towards activation-service-type))
                                         '()))
                                       "/var/lib/prometheus/node-exporter")
                            #:name "The activation creates node exporter's textfile directory"))

         (test "Textfiles are replaced atomically"
               (assert-true (contains? disk-report "mktemp")
                            #:name "The new file is written under a temporary name")
               (assert-true (contains? disk-report "mv -f \"$tmp\"")
                            #:name "The temporary file is renamed into place")
               (assert-true (contains? disk-report
                                       "/var/lib/prometheus/node-exporter/wolk_disk.prom")
                            #:name "It lands in node exporter's textfile directory")
               (assert-true (contains? disk-report "wolk_disk.prom.XXXXXX")
                            #:name "And never as a partial .prom file"))

         (test "The disk report publishes what the alerts need"
               (assert-true (contains? disk-report "wolk_backup_archive_count{project=")
                            #:name "One series per project, with a project label")
               (assert-true (contains? disk-report
                                       "wolk_backup_newest_timestamp_seconds{project=")
                            #:name "The newest archive of each project is dated")
               (assert-true (contains? disk-report "${newest:-0}")
                            #:name "A project without archives reports 0, not nothing")
               (assert-true (contains? disk-report "wolk_disk_report_timestamp_seconds")
                            #:name "The report dates itself, so a stale report is visible")
               (assert-true (contains? disk-report "/wolk-jjba-backups")
                            #:name "The backup tree is the thing being reported"))

         (test "The Guix collection frees generations before the store"
               (assert-true (contains? guix-gc "guix system delete-generations 14d")
                            #:name "Old system generations go first")
               (assert-true (contains? guix-gc "guix home delete-generations 14d")
                            #:name "joe's home generations go too")
               (assert-true (contains? guix-gc "guix gc -d 14d")
                            #:name "The store keeps the same fortnight")
               (assert-true (contains? guix-gc "sudo -u joe env HOME=/home/joe")
                            #:name "The home profile is pruned as its owner")
               (assert-true (contains? guix-gc "guix gc")
                            #:name "The store is collected afterwards")
               (assert-true (contains? guix-gc "wolk_guix_store_bytes")
                            #:name "The size of the store is published"))

         (test "The collection keeps a count of generations, not just a window"
               ;; A duration alone does not bound this machine: it
               ;; reconfigures two or three times on a busy day, so
               ;; 14d was still keeping thirty system generations, and
               ;; every one of them pins a whole system closure.
               (assert-true (contains? guix-gc
                                       "generations_of /var/guix/profiles system")
                            #:name "The system profile's generations are counted")
               (assert-true (contains? guix-gc
                                       "generations_of /var/guix/profiles/per-user/joe guix-home")
                            #:name "Home generations are counted too")
               (assert-true (contains? guix-gc "| head -n -5)")
                            #:name "The newest five survive and the rest are named")
               (assert-true (contains? (guix-gc-job #:keep-generations 3)
                                       "| head -n -3)")
                            #:name "The count is a knob")
               (assert-true (not (contains? guix-gc "ls /var/guix/profiles/system"))
                            #:name
                            "The generations are read as links, not with ls, which follows them")
               (assert-true (contains? guix-gc "tr ' ' ','")
                            #:name
                            "The pattern is comma-separated: guix takes one pattern, and no ranges")
               (assert-true (contains? guix-gc
                                       "[ -e \"$link\" ] || [ -L \"$link\" ]")
                            #:name "A link whose store item is gone is still counted"))

         (test "Pruning podman state leaves volumes alone"
               (assert-true (contains? podman-prune "podman system prune --force")
                            #:name "Unused containers, images and build cache go")
               (assert-true (contains? podman-prune "--filter until=168h")
                            #:name "Only things untouched for a week")
               (assert-true (not (contains? podman-prune "--volumes"))
                            #:name "Volumes are never pruned: a container may own data there")
               (assert-true (contains? podman-prune "byggsteg-runner")
                            #:name "The CI runner's images are pruned too"))

         (test "The caches that are deleted are download caches"
               (assert-true (contains? cache-clean ".npm/_cacache")
                            #:name "The npm cache goes")
               (assert-true (contains? cache-clean ".cache/pip")
                            #:name "The pip cache goes")
               (assert-true (contains? cache-clean "rm -rf")
                            #:name "The cache is removed, not truncated"))

         (test "The temporary-file cleanup spares sockets"
               (assert-true (contains? tmp-clean "! -type s")
                            #:name "A long-running daemon keeps its socket")
               (assert-true (contains? tmp-clean "-mtime +7")
                            #:name "Only week-old files are candidates")
               (assert-true (contains? tmp-clean "/var/tmp")
                            #:name "Both temporary directories are covered"))

         (test "The backup verification actually reads the archive"
               (assert-true (contains? verify-backups "sha256sum --quiet -c")
                            #:name "The checksum sidecar is checked")
               (assert-true (contains? verify-backups "tar -tzf -")
                            #:name "A tar archive is listed through a pipe")
               (assert-true (contains? verify-backups "gzip -t")
                            #:name "An SQL dump is tested through a pipe")
               (assert-true (contains? verify-backups "exit $failed")
                            #:name "A failed verification fails the job")
               (assert-true (contains? verify-backups
                                       "wolk_backup_verified_timestamp_seconds{project=")
                            #:name "A success is published, so a stale check is visible")
               (assert-true (not (contains? verify-backups "/tmp/.wolk-verify"))
                            #:name "Nothing is decrypted to a temporary file"))

         (test "The disk report says when the off-site mirror last worked"
               (assert-true (contains? disk-report
                                       "wolk_backup_upload_last_success_timestamp_seconds")
                            #:name "The hourly mirror's last successful run is a metric")
               (assert-true (contains? disk-report "/var/lib/wolk-gfs/last-upload")
                            #:name "It comes from the marker the mirror job writes")
               (assert-true (contains? disk-report
                                       "wolk_backup_upload_last_success_timestamp_seconds 0")
                            #:name "A mirror that never ran reports 0, so its age is enormous")
               (assert-true (contains? disk-report "/root/.cache")
                            #:name "Caches outside the backup tree are sized too")
               (assert-true (contains? disk-report "/root/.m2")
                            #:name "A Java build cache is a disk consumer as well"))

         (test "The symbanta events window is two months, applied in batches"
               (assert-true (contains? events-retention "interval '2 months'")
                            #:name "Two calendar months, not a count of days")
               (assert-true (contains? events-retention "DELETE FROM public.events")
                            #:name "The events table is the one pruned")
               (assert-true (contains? events-retention
                                       "(SELECT id FROM public.events WHERE created_at < now() - interval '2 months' LIMIT 5000)")
                            #:name "Rows are chosen by age and deleted in batches")
               (assert-true (contains? events-retention "lock_timeout = '5s'")
                            #:name "A batch gives up rather than blocking the API")
               (assert-true (contains? events-retention "VACUUM (ANALYZE) public.events;")
                            #:name "The freed space and the statistics are reclaimed")
               (assert-true (not (contains? events-retention "VACUUM FULL"))
                            #:name "No exclusive lock is taken behind the application")
               (assert-true (contains? events-retention "-d app_db")
                            #:name "It connects to symbanta's database")
               (assert-true (contains? events-retention "sudo -u postgres")
                            #:name "Peer authentication is satisfied as the postgres role")
               (assert-true (not (contains? events-retention "app_users"))
                            #:name "Only the events table is touched: accounts stay")
               (assert-true (not (contains? events-retention "flyway_schema_history"))
                            #:name "The schema history is never a retention candidate")
               (assert-true (contains? events-retention "wolk_postgres_events_expired")
                            #:name "Rows that are still too old are a metric")
               (assert-true (contains? events-retention
                                       "/var/lib/prometheus/node-exporter/wolk_postgres.prom")
                            #:name "The numbers land in node exporter's textfile directory")
               (assert-true (contains? events-retention "mktemp")
                            #:name "The textfile is written atomically")
               (assert-true (contains?
                             (object->string
                              (gexp->approximate-sexp
                               (shepherd-service-start
                                (timer-named 'prune-symbanta-events))))
                             "20 3 * * *")
                            #:name "It runs daily, away from the dump hours"))))

(define (spec)
  (veritas-run maintenance-suite))
