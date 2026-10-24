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
;; Disk hygiene for a machine that is expected to run for years on one
;; fixed disk: the jobs here are the ones that give space *back*, and
;; the ones that make the giving-back measurable.
;;
;; Six things grow on this host, and each has a job:
;;
;;   /gnu/store      every reconfigure and every guix pull adds a
;;                   generation.  keep-generations + guix gc.
;;   /nix/store      the dev profile of joe.  nix-store --gc.
;;   podman storage  byggsteg builds in containers; images and build
;;                   cache are never reused after a week.  prune.
;;   user caches     npm, pip, yarn and node-gyp caches are pure
;;                   downloads.  delete.
;;   /tmp, /var/tmp  files nobody has touched for a week.  delete.
;;   /wolk-jjba-backups  bounded by the prune timers in (wolk-jjba
;;                   jobs) -- this module reports on it, verifies it,
;;                   and never deletes an archive.
;;
;; The reporting half matters as much as the deleting half: node
;; exporter reads the textfiles written here and exposes them, so
;; "the disk is filling" and "the last backup is two days old" are
;; alerts (see monitoring/alerting/alert-rules.yml), not things found
;; out the day a restore is needed.
;;
;; Every job runs as root under the Shepherd, logs to
;; /var/log/wolk-jjba/<job>.log, and can be triggered by hand:
;;
;;   sudo herd trigger guix-gc
;;   sudo herd trigger disk-report
;;   sudo herd trigger verify-backups
;;
;; None of them overlaps the backup jobs of (wolk-jjba jobs): the gc
;; runs on Sunday night, podman and the caches on Saturday morning, and
;; the two that touch the backup tree only read from it.
;;
;; Code:

(define-module (wolk-jjba maintenance)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services admin)
  #:use-module (ice-9 format)
  #:use-module (wolk-jjba containers)
  #:use-module (wolk-jjba gfs)
  #:use-module (wolk-jjba jobs)
  #:export (maintenance-capability
            maintenance-service-type
            maintenance-jobs
            maintenance-log-files
            wolk-jjba-metrics-directory
            disk-report-job
            guix-gc-job
            nix-gc-job
            podman-prune-job
            cache-clean-job
            tmp-clean-job
            verify-backups-job
            gfs-backup-program
            textfile-script))

;; Where node exporter looks for *.prom files.  It is the default
;; `textfile-directory' of prometheus-node-exporter-configuration, which
;; is what config.scm instantiates; keep the two in step if it changes.
(define wolk-jjba-metrics-directory
  "/var/lib/prometheus/node-exporter")

;; ====== Prometheus textfiles ======

(define (textfile-script file body)
  "Return a shell script that replaces FILE in the metrics directory
with the output of BODY.

BODY must write *only* metric lines to standard output: node exporter
refuses a textfile that contains anything else, and a rejected file
makes every series in it disappear.  Progress messages therefore go to
standard error, which the Shepherd writes to the job log.

node exporter reads every *.prom file in its textfile directory once
per scrape.  A scrape that lands in the middle of a write sees a
truncated line, and the metrics that were already there disappear from
that scrape -- which resets a `rate()' and makes an alert flap between
firing and resolved.  Writing to a temporary file in the same directory
and renaming it into place means a scrape sees either the old file or
the new one, never a fragment."
  (format #f "set -uo pipefail
mkdir -p ~a
tmp=\"$(mktemp ~a/.~a.XXXXXX)\"
trap 'rm -f \"$tmp\"' EXIT
{
~a
} > \"$tmp\"
chmod 0644 \"$tmp\"
mv -f \"$tmp\" ~a/~a
trap - EXIT"
          wolk-jjba-metrics-directory
          wolk-jjba-metrics-directory
          file
          body
          wolk-jjba-metrics-directory
          file))

;; ====== Disk report ======

(define* (disk-report-job #:key (backup-root wolk-jjba-backup-root))
  "Return the script of the hourly backup-tree report.

Three numbers per project -- how many archives exist, how many bytes
they take, and how old the newest one is -- plus the size of every
directory the stack owns.  The age is what the alerting needs: a backup
job that stops running (a broken SQLite snapshot, a full disk, a typo
in a path) leaves the previous archives in place, so the directory
still looks healthy while the data it protects is unprotected.  The
timestamp is emitted as 0 for a project with no archive at all, which
makes `time() - ...' huge on purpose (see the alerts)."
  (textfile-script
   "wolk_disk.prom"
   (format #f "printf '# HELP wolk_backup_archive_count Number of encrypted archives kept locally, per project.\\n'
printf '# TYPE wolk_backup_archive_count gauge\\n'
printf '# HELP wolk_backup_bytes Bytes of the encrypted archives and their checksums, per project.\\n'
printf '# TYPE wolk_backup_bytes gauge\\n'
printf '# HELP wolk_backup_newest_timestamp_seconds Modification time of the newest archive of a project, or 0 when there is none.\\n'
printf '# TYPE wolk_backup_newest_timestamp_seconds gauge\\n'
for dir in ~a/*/; do
  [ -d \"$dir\" ] || continue
  project=\"${dir%/}\"
  project=\"${project##*/}\"
  count=$(find \"$dir\" -maxdepth 1 -type f -name '*.enc' | wc -l)
  bytes=$(find \"$dir\" -maxdepth 1 -type f -name '*.enc*' -printf '%s\\n' | awk '{ total += $1 } END { print total + 0 }')
  newest=$(find \"$dir\" -maxdepth 1 -type f -name '*.enc' -printf '%T@\\n' | sort -rn | head -n 1 | cut -d. -f1)
  printf 'wolk_backup_archive_count{project=\"%s\"} %s\\n' \"$project\" \"$count\"
  printf 'wolk_backup_bytes{project=\"%s\"} %s\\n' \"$project\" \"$bytes\"
  printf 'wolk_backup_newest_timestamp_seconds{project=\"%s\"} %s\\n' \"$project\" \"${newest:-0}\"
done
printf '# HELP wolk_dir_bytes Bytes used by a directory the stack owns.\\n'
printf '# TYPE wolk_dir_bytes gauge\\n'
for path in /var/lib/prometheus /var/lib/loki /var/lib/tempo /var/lib/alloy /var/lib/grafana /var/log ~a; do
  [ -e \"$path\" ] || continue
  printf 'wolk_dir_bytes{path=\"%s\"} %s\\n' \"$path\" \"$(du -sb \"$path\" 2>/dev/null | cut -f1)\"
done
printf '# HELP wolk_disk_report_timestamp_seconds When the disk report last ran.\\n'
printf '# TYPE wolk_disk_report_timestamp_seconds gauge\\n'
printf 'wolk_disk_report_timestamp_seconds %s\\n' \"$(date +%s)\"
printf '# HELP wolk_gfs_last_success_timestamp_seconds When the GFS retention run last succeeded (0 when it never has).\\n'
printf '# TYPE wolk_gfs_last_success_timestamp_seconds gauge\\n'
if [ -r ~a/last-success ]; then
  printf 'wolk_gfs_last_success_timestamp_seconds %s\\n' \"$(head -n 1 ~a/last-success)\"
else
  printf 'wolk_gfs_last_success_timestamp_seconds 0\\n'
fi
printf '# HELP wolk_archive_backups Long-term archives kept on the Storage Box, per project.\\n'
printf '# TYPE wolk_archive_backups gauge\\n'
if [ -r ~a/archive-counts ]; then
  while read -r project count; do
    [ -n \"$project\" ] && printf 'wolk_archive_backups{project=\"%s\"} %s\\n' \"$project\" \"$count\"
  done < ~a/archive-counts
fi"
           backup-root
           backup-root
           %gfs-marker-directory
           %gfs-marker-directory
           %gfs-marker-directory
           %gfs-marker-directory)))

;; ====== Garbage collection ======

(define* (guix-gc-job #:key
                      (delete-older-than "30d")
                      (user "joe")
                      (home "/home/joe"))
  "Return the script of the weekly Guix garbage collection.

Generations are what actually pins the store: `guix gc' cannot delete a
single object that an old system generation still references, which is
why the compile products of a year of reconfigures survive a plain gc.
So the generations go first, and the retention rule is a duration --
`30d', the syntax Guix itself documents for this -- rather than a
count: `guix system delete-generations 5' would mean \"delete
generation 5\", not \"keep five\", and a month of rollback targets is
more than enough for a machine that reconfigures weekly.

The store is collected afterwards, as root, so that the per-user
profiles under /var/guix/profiles/per-user are all treated as roots and
the other users' garbage is collected too.

The size of the store afterwards is written to the metrics directory,
so a store that stops shrinking (a generation that keeps being
referenced, a package pinned by a running daemon) shows up on the
storage dashboard instead of in a `df' one morning."
  (string-join
   (list
    "set -uo pipefail"
    "echo '== generations ==============================================='"
    (format #f "guix system delete-generations ~a || echo 'guix system delete-generations: nothing to delete'"
            delete-older-than)
    ;; joe's home environment lives in joe's own per-user profile, so
    ;; its generations can only be deleted as joe.  The job itself runs
    ;; as root and HOME=/root; the explicit env is what makes guix find
    ;; the right profile.
    (format #f "sudo -u ~a env HOME=~a guix home delete-generations ~a || echo 'guix home delete-generations: nothing to delete'"
            user home delete-older-than)
    "echo '== collecting garbage ========================================'"
    (format #f "guix gc -d ~a || echo 'guix gc -d: nothing to delete'"
            delete-older-than)
    "guix gc || echo 'guix gc failed'"
    "echo '== store ====================================================='"
    "df -h /gnu/store || true"
    "du -sh /gnu/store || true"
    (textfile-script
     "wolk_guix.prom"
     "printf '# HELP wolk_guix_store_bytes Bytes in /gnu/store, measured after the last garbage collection.\\n'
printf '# TYPE wolk_guix_store_bytes gauge\\n'
printf 'wolk_guix_store_bytes %s\\n' \"$(du -sb /gnu/store 2>/dev/null | cut -f1)\"
printf '# HELP wolk_guix_gc_timestamp_seconds When the Guix garbage collection last finished.\\n'
printf '# TYPE wolk_guix_gc_timestamp_seconds gauge\\n'
printf 'wolk_guix_gc_timestamp_seconds %s\\n' \"$(date +%s)\""))
   "\n"))

(define (nix-gc-job)
  "Return the script of the weekly Nix store collection.

The Nix dev profile of joe is a convenience, not a service, so a
failure here must not fail the job of the day: `|| echo' keeps the log
readable on a machine where Nix is absent."
  "set -uo pipefail
echo '== nix store =================================================='
nix-store --gc || echo 'nix-store --gc failed (is Nix installed?)'")

;; ====== Container and cache cleanup ======

(define* (podman-prune-job #:key (users podman-users))
  "Return the script that prunes stale rootless podman state.

Byggsteg builds every job that names an image in a container, so images
and build cache accumulate for as long as the CI runs -- by far the
fastest-growing directory on this host after /gnu/store.  An image
nobody has run for a week is not going to be reused (the registry copy
is one `podman pull' away), while the storage it holds is never given
back on its own.

The same two accounts the (wolk-jjba containers) capability configures
are pruned, because those are the accounts whose storage holds images:
joe's, for the suites and scratch containers started by hand, and
byggsteg-runner's, for the CI's own builds.

Two deliberate omissions: volumes are *not* pruned (`--volumes' would
delete named volumes a container may own data in), and the filter only
removes things untouched for a week, so a build that is running right
now is left alone.  `--build' is passed so that the build cache an image
build leaves behind is collected too; it removes build containers and
their cache, never an image that is still referenced.

Rootless podman needs its own runtime directory.  (wolk-jjba containers)
creates /run/user/<uid> at boot, so the directory is there even for the
account that never logs in; a machine without that capability still
reports the skip rather than failing the job."
  (string-join
   (list
    "set -uo pipefail"
    (string-join
     (map (lambda (user)
            (format #f "uid=$(id -u ~a 2>/dev/null || true)
if [ -n \"$uid\" ]; then
  echo '== podman: ~a ================================================'
  home=$(getent passwd ~a | cut -d: -f6)
  sudo -u ~a env HOME=\"$home\" XDG_RUNTIME_DIR=\"/run/user/$uid\" DOCKER_HOST=\"unix:///run/user/$uid/podman/podman.sock\" podman system df || true
  sudo -u ~a env HOME=\"$home\" XDG_RUNTIME_DIR=\"/run/user/$uid\" DOCKER_HOST=\"unix:///run/user/$uid/podman/podman.sock\" podman system prune --force --build --filter until=168h || echo 'podman prune skipped (no session or no podman state)'
else
  echo 'podman: user ~a does not exist, skipped'
fi"
                    user user user user user user))
          users)
     "\n")
    "echo '== done ======================================================'")
   "\n"))

(define* (cache-clean-job #:key
                          (users '("joe" "byggsteg-runner"))
                          (caches '(".npm/_cacache"
                                    ".cache/pip"
                                    ".cache/yarn"
                                    ".cache/node-gyp")))
  "Return the script that deletes the download caches of USERS.

These directories exist only to avoid downloading the same tarball
twice; deleting them costs a slower first build and nothing else.
Everything the applications actually need is in their checkout or in
the store, so this is the cheapest space a job can reclaim."
  (string-join
   (list
    "set -uo pipefail"
    (string-join
     (map (lambda (user)
            (format #f "home=$(getent passwd ~a | cut -d: -f6)
if [ -n \"$home\" ] && [ -d \"$home\" ]; then
  for cache in ~a; do
    if [ -e \"$home/$cache\" ]; then
      size=$(du -sh \"$home/$cache\" 2>/dev/null | cut -f1)
      rm -rf \"$home/$cache\"
      echo \"~a: removed $home/$cache ($size)\"
    fi
  done
else
  echo 'cache-clean: user ~a does not exist, skipped'
fi"
                    user
                    (string-join caches " ")
                    user
                    user))
          users)
     "\n"))
   "\n"))

(define* (tmp-clean-job #:key
                        (directories '("/tmp" "/var/tmp"))
                        (days 7))
  "Return the script that removes week-old temporary files.

Sockets are excluded on purpose: a long-running daemon creates its
socket once and never touches it again, so its mtime is as old as the
daemon -- deleting the inode would silently make the daemon
unreachable while it is running.  The well-known X11 and font
directories are excluded for the same reason."
  (string-join
   (list
    "set -uo pipefail"
    (string-join
     (map (lambda (directory)
            (format #f "if [ -d ~a ]; then
  echo '== ~a ======================================================='
  find ~a -mindepth 1 -maxdepth 1 ! -type s ! -name '.X11-unix' ! -name '.ICE-unix' ! -name '.XIM-unix' ! -name '.font-unix' -mtime +~a -print -exec rm -rf {} + || echo 'cleanup of ~a failed'
fi"
                    directory directory directory days directory))
          directories)
     "\n"))
   "\n"))

;; ====== Long-term retention on the Storage Box ======

;; The GFS job is a Scheme program, not a shell script: its retention
;; rules live in (wolk-jjba gfs), where the test suite can run them
;; against an in-memory Storage Box.
;;
;; `source-module-closure' defaults to Guix's own modules (its SELECT?
;; predicate is `guix-module-name?'), so the repository's namespace has
;; to be named explicitly or the closure comes back empty and the
;; program fails at run time with "no code for module (wolk-jjba gfs)".
;; Selecting only `wolk-jjba' modules is also what keeps the closure
;; small: everything else the module imports is Guile's own standard
;; library, which the interpreter already has.
(define (wolk-jjba-module? name)
  "Return #t for a module name that this repository provides."
  (and (pair? name) (eq? (car name) 'wolk-jjba)))

(define gfs-backup-program
  (program-file "gfs-backup"
    (with-imported-modules (source-module-closure '((wolk-jjba gfs))
                                                 #:select? wolk-jjba-module?)
      #~(begin
          (use-modules (wolk-jjba gfs))
          ;; The program *is* the server job, so it applies.  The dry
          ;; run is what a human gets from `maak gfs-backup' and from
          ;; scripts/gfs-backup.scm, where a mistake costs an archive.
          (exit (main #:argv (list "gfs-backup" "--apply")))))))

(define gfs-backup-service
  (make-timer-service
   #:name 'gfs-backup
   #:schedule "45 2 * * *"
   #:program gfs-backup-program
   ;; It talks to the same Storage Box as the hourly mirror, so it runs
   ;; as the same user: that is the account whose ~/.ssh/config has the
   ;; wolkenschlosslagerung alias and whose key is authorised on the
   ;; box.
   #:user "backer-upper"
   #:group "users"
   #:home "/home/backer-upper"
   #:requirement '(user-processes file-systems networking)
   #:max-duration 7200
   #:documentation
   "Promote one archive per week and per month into the long-term tree on the Storage Box, and prune it with the GFS rules."))

;; ====== Backup verification ======

(define* (verify-backups-job #:key
                             (backup-root wolk-jjba-backup-root)
                             (password-file "$HOME/.backup-password"))
  "Return the script that verifies the newest archive of every project.

A backup nobody has tried to restore is a hypothesis.  Three things can
be wrong with an archive that looks perfect in `ls': the mirror copied
it but a bit flipped (hence the sha256 sidecar the backup job writes);
the passphrase in /root/.backup-password is not the one it was
encrypted with (a rotated password); or the compressed stream never
finished being written (a truncated gzip stream is not detected by
openssl at all).

Each of those shows up here, by decrypting the newest archive and
walking it -- `tar -tzf' for a tar archive, `gzip -t' for an SQL dump
-- through a pipe, so a multi-gigabyte Minecraft archive never has to
be written somewhere first.  A success is published as a timestamp, so
\"the verification has not run in ten days\" is an alert as well.

The job exits non-zero when any project fails, which is what makes the
failure visible in `herd status verify-backups' and in the job log."
  (string-append
   (textfile-script
    "wolk_backup_verify.prom"
    (format #f "failed=0
printf '# HELP wolk_backup_verified_timestamp_seconds When the newest archive of a project was last decrypted and read back successfully.\\n'
printf '# TYPE wolk_backup_verified_timestamp_seconds gauge\\n'
check_archive() {
  case \"$1\" in
    *.tar.gz.enc) openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 -in \"$1\" -pass \"file:~a\" | tar -tzf - > /dev/null ;;
    *.sql.gz.enc) openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 -in \"$1\" -pass \"file:~a\" | gzip -t ;;
    *) openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 -in \"$1\" -pass \"file:~a\" > /dev/null ;;
  esac
}
for dir in ~a/*/; do
  [ -d \"$dir\" ] || continue
  project=\"${dir%/}\"
  project=\"${project##*/}\"
  newest=$(find \"$dir\" -maxdepth 1 -type f -name '*.enc' -printf '%T@\\t%p\\n' | sort -t \"$(printf '\\t')\" -k1,1 -rn | head -n 1 | cut -f2-)
  if [ -z \"$newest\" ]; then
    echo \"$project: no archive to verify\" >&2
    failed=1
    continue
  fi
  if [ -f \"$newest.sha256\" ]; then
    ( cd \"$dir\" && sha256sum --quiet -c \"$(basename \"$newest\").sha256\" >&2 ) || { echo \"$project: CHECKSUM MISMATCH for $newest\" >&2; failed=1; continue; }
  else
    echo \"$project: $newest has no .sha256 sidecar (written by an older job)\" >&2
  fi
  if check_archive \"$newest\"; then
    echo \"$project: OK $newest\" >&2
    printf 'wolk_backup_verified_timestamp_seconds{project=\"%s\"} %s\\n' \"$project\" \"$(date +%s)\"
  else
    echo \"$project: FAILED to decrypt or read $newest\" >&2
    failed=1
  fi
done"
            password-file
            password-file
            password-file
            backup-root))
   "\nexit $failed\n"))

;; ====== Timer services ======

(define disk-report-service
  (make-timer-service
   #:name 'disk-report
   #:schedule "7 * * * *"
   #:script (disk-report-job)
   #:requirement '(user-processes file-systems networking)
   #:max-duration 900
   #:documentation
   "Write the backup and directory size metrics to node exporter's textfile directory."))

(define guix-gc-service
  (make-timer-service
   #:name 'guix-gc
   #:schedule "0 3 * * 0"
   #:script (guix-gc-job)
   #:max-duration 14400
   #:documentation
   "Delete old Guix generations and garbage-collect the store."))

(define nix-gc-service
  (make-timer-service
   #:name 'nix-gc
   #:schedule "30 3 * * 0"
   #:script (nix-gc-job)
   #:max-duration 3600
   #:documentation "Garbage-collect the Nix store."))

(define verify-backups-service
  (make-timer-service
   #:name 'verify-backups
   #:schedule "0 4 * * 0"
   #:script (verify-backups-job)
   #:max-duration 3600
   #:documentation
   "Decrypt and read the newest archive of every project."))

(define podman-prune-service
  (make-timer-service
   #:name 'podman-prune
   #:schedule "0 4 * * 6"
   #:script (podman-prune-job)
   #:max-duration 3600
   #:documentation
   "Prune container images and build cache older than a week."))

(define cache-clean-service
  (make-timer-service
   #:name 'cache-clean
   #:schedule "30 4 * * 6"
   #:script (cache-clean-job)
   #:max-duration 3600
   #:documentation
   "Delete the npm, pip, yarn and node-gyp caches of the build users."))

(define tmp-clean-service
  (make-timer-service
   #:name 'tmp-clean
   #:schedule "45 4 * * *"
   #:script (tmp-clean-job)
   #:max-duration 1800
   #:documentation
   "Remove temporary files in /tmp and /var/tmp that are a week old."))

;; ====== Service type ======

(define maintenance-jobs
  (list disk-report-service
        guix-gc-service
        nix-gc-service
        verify-backups-service
        gfs-backup-service
        podman-prune-service
        cache-clean-service
        tmp-clean-service))

(define maintenance-log-files
  (map (lambda (job)
         (format #f "/var/log/wolk-jjba/~a.log"
                 (car (shepherd-service-provision job))))
       maintenance-jobs))

(define maintenance-service-type
  (service-type
   (name 'wolk-jjba-maintenance)
   (extensions
    (list (service-extension
           shepherd-root-service-type
           (const maintenance-jobs))
          (service-extension
           activation-service-type
           (const #~(begin
                      (use-modules (guix build utils))
                      (mkdir-p "/var/log/wolk-jjba")
                      ;; node exporter's own activation creates this
                      ;; directory too, and owns it; creating it here as
                      ;; well only guarantees the first disk report does
                      ;; not race a machine where node exporter has been
                      ;; configured with a different textfile directory.
                      (mkdir-p #$wolk-jjba-metrics-directory)
                      (chmod #$wolk-jjba-metrics-directory #o755)
                      ;; The GFS job runs unprivileged and leaves its run
                      ;; marker here; the hourly disk report (root) turns
                      ;; that marker into metrics, so node exporter's
                      ;; textfile directory never has to be writable by
                      ;; the backup user.
                      (mkdir-p #$%gfs-marker-directory)
                      (chmod #$%gfs-marker-directory #o755)
                      (let ((pw (getpwnam "backer-upper")))
                        (when pw
                          (chown #$%gfs-marker-directory
                                 (passwd:uid pw)
                                 (passwd:gid pw)))))))
          (service-extension
           log-rotation-service-type
           (const maintenance-log-files))))
   (default-value '())
   (description
    "Garbage-collect the stores, prune containers and caches, verify the
backups and publish disk metrics as Shepherd timer jobs.")))

(define (maintenance-capability)
  (service maintenance-service-type))
