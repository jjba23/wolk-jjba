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

(define maintenance-suite
  (suite "Maintenance Suite"

         (test "Every maintenance job is scheduled exactly once"
               (assert-equal #:expect '(disk-report guix-gc nix-gc
                                                     verify-backups gfs-backup
                                                     podman-prune cache-clean
                                                     tmp-clean)
                             #:got timer-names
                             #:name "The eight jobs are the documented ones")
               (assert-equal #:expect 8
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
                               "/var/log/wolk-jjba/tmp-clean.log")
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
               (assert-true (contains? guix-gc "guix system delete-generations 30d")
                            #:name "Old system generations go first")
               (assert-true (contains? guix-gc "guix home delete-generations 30d")
                            #:name "joe's home generations go too")
               (assert-true (contains? guix-gc "sudo -u joe env HOME=/home/joe")
                            #:name "The home profile is pruned as its owner")
               (assert-true (contains? guix-gc "guix gc")
                            #:name "The store is collected afterwards")
               (assert-true (contains? guix-gc "wolk_guix_store_bytes")
                            #:name "The size of the store is published"))

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
                            #:name "Nothing is decrypted to a temporary file"))))

(define (spec)
  (veritas-run maintenance-suite))
