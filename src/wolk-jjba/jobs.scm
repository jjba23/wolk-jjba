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
;;
;; An archive is built in three steps that can each be re-run on their
;; own, and every step is written so that a failure leaves the backup
;; directory exactly as it was:
;;
;;   1. the input is captured *consistently*: a SQLite database is
;;      snapshotted with `sqlite3 .backup' (which reads a transaction,
;;      unlike a plain tar of a live .db + -wal + -shm set, whose three
;;      files are copied at three different moments), and PostgreSQL is
;;      dumped with pg_dumpall;
;;   2. the capture is tarred (or gzipped) and encrypted into a
;;      `.part' file, which is only renamed to `.enc' once openssl has
;;      exited successfully;
;;   3. a sha256 sidecar is written next to the archive, so a mirror
;;      copy can be checked before it is restored.
;;
;; Pruning deletes only regular files that match the archive pattern,
;; removes the `.sha256' sidecar together with its archive, and cleans
;; up leftovers of an interrupted run.  It never touches directories,
;; so an unexpected file in a backup directory is reported by `find'
;; in the log instead of being deleted.
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
            make-dump-backups-job
            clean-backups-job
            make-timer-service
            wolk-jjba-backup-root))

;; ====== Shell command builders ======

;; The local backup tree.  Everything below lives in one directory per
;; project, and the Storage Box mirror copies the tree as it is.
(define wolk-jjba-backup-root
  "/wolk-jjba-backups")

;; Shared by every backup job: encrypt the archive that the capture step
;; left as ./$ARCHIVE, write its checksum and move both into place.
;;
;; The `.part' suffix is what makes a failure harmless.  openssl writes
;; to $ARCHIVE.enc.part, and only a successful exit renames it to
;; $ARCHIVE.enc; if the job dies half-way (a full disk, a kill from
;; `herd', a reboot) the backup directory keeps no file that looks like
;; a usable archive, and the mirror never uploads a truncated one.  The
;; rename is atomic because both names are in the same directory.
(define (encrypt-and-store-commands dest-dir)
  (list "openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in \"./$ARCHIVE\" -out \"./$ARCHIVE.enc.part\" -pass file:\"$HOME/.backup-password\""
        "mv \"./$ARCHIVE.enc.part\" \"./$ARCHIVE.enc\""
        "sha256sum -- \"./$ARCHIVE.enc\" > \"./$ARCHIVE.enc.sha256\""
        (format #f "mv \"./$ARCHIVE.enc\" \"./$ARCHIVE.enc.sha256\" ~a/"
                dest-dir)))

(define* (make-backups-job #:key
                           pwd
                           dest-dir
                           name
                           (includes '())
                           (sqlite-dbs '()))
  "Return a shell script that archives, encrypts and stores a backup.

INCLUDES are tarred exactly as they are on disk.  SQLITE-DBS are
instead snapshotted first with `sqlite3 .backup', and the snapshot --
not the live file -- is what the archive contains.

That distinction is the point of the SQLITE-DBS argument.  An
application keeps a database open, so `wikimusic.db', its `-wal' and
its `-shm' are copied by tar at three different moments: the result can
contain a transaction in the WAL but not in the database file, or a
`-shm' index that no longer matches the `-wal' it was copied with.
SQLite cannot detect that afterwards -- it is not corruption, it is a
consistent view of three separate instants -- so the archive looks fine
until it is restored.  `sqlite3 .backup' opens a read transaction and
copies one consistent database, which is also all that a restore needs.

Each snapshot is checked with `PRAGMA quick_check' before it is stored,
so a database that is already damaged is reported by the backup job
instead of being discovered on the day of the restore."
  (string-join
   (append
    (list "set -euo pipefail"
          (format #f "mkdir -p ~a" dest-dir)
          (format #f "cd ~a" pwd)
          "WORK=\"$(mktemp -d)\""
          (format #f "ARCHIVE=\"~a-$(date +%s).tar.gz\"" name)
          "trap 'rm -rf \"$WORK\"; rm -f \"./$ARCHIVE\" \"./$ARCHIVE.enc.part\"' EXIT")
    ;; `sqlite3' resolves the dot-command relative to its working
    ;; directory, which is why the snapshot is taken in a subshell --
    ;; the file name then needs no quoting, however odd it is.
    (apply
     append
     (map (lambda (db)
            (list (format #f
                          "( cd \"$WORK\" && sqlite3 -- ~a/~a \".backup ~a\" )"
                          pwd db db)
                  (format #f
                          "test \"$(sqlite3 -- \"$WORK/~a\" 'PRAGMA quick_check')\" = ok"
                          db)))
          sqlite-dbs))
    (list (string-join
           (append (list "tar -czf \"./$ARCHIVE\"")
                   includes
                   (if (null? sqlite-dbs)
                       '()
                       (append (list "-C \"$WORK\"") sqlite-dbs)))
           " "))
    (encrypt-and-store-commands dest-dir))
   " && "))

(define* (make-dump-backups-job #:key dest-dir name command suffix)
  "Return a shell script that stores the output of COMMAND as a backup.

COMMAND is expected to write a text dump to standard output (pg_dumpall
does).  Its output is stored as ARCHIVE with the SUFFIX extension --
`sql.gz' here, so `gzip' does the compressing -- and the result is
encrypted and checksummed exactly like a tar archive.  A dump is not
read from a live file set, so it needs no snapshotting: the database
server does that itself."
  (string-join
   (append
    (list "set -euo pipefail"
          (format #f "mkdir -p ~a" dest-dir)
          "WORK=\"$(mktemp -d)\""
          (format #f "ARCHIVE=\"~a-$(date +%s).~a\"" name suffix)
          "trap 'rm -rf \"$WORK\"; rm -f \"./$ARCHIVE\" \"./$ARCHIVE.enc.part\"' EXIT"
          "cd \"$WORK\""
          (format #f "~a > \"$WORK/$ARCHIVE\"" command)
          ;; An empty dump is not a backup; `test -s' turns a silent
          ;; failure (a wrong socket, a missing database) into a failed
          ;; job instead of an archive nobody can restore.
          "test -s \"$WORK/$ARCHIVE\"")
    (encrypt-and-store-commands dest-dir))
   " && "))

(define* (clean-backups-job #:key
                            pwd
                            keep-amount
                            (keep-days #f)
                            (pattern "*.enc"))
  "Return a shell script that prunes the archives in PWD.

The KEEP-AMOUNT newest archives (by modification time) survive;
everything else that matches PATTERN is removed, together with its
`.sha256' sidecar.  When KEEP-DAYS is a number, archives older than
that are removed as well, even if fewer than KEEP-AMOUNT remain: an
archive that is a year old is not useful just because the host was
quiet for a year.

Only *regular files* matching PATTERN are candidates.  The previous
implementation pruned with `ls -A1t | tail -n +N | xargs rm', which
deleted whatever happened to sort last -- a directory, a README, the
checksum files -- so a single stray file in a backup directory could
cost an archive.  The leftovers of an interrupted run (an unencrypted
tarball, a `.part' file) are removed separately once they are a day
old, so an archive that is still being written is never touched."
  (string-join
   (append
    (list "set -uo pipefail"
          (format #f "cd ~a" pwd)
          ;; Newest first, drop the KEEP+1-th and everything after it.
          (format #f "find . -maxdepth 1 -type f -name '~a' -printf '%T@\\t%p\\n' | sort -t \"$(printf '\\t')\" -k1,1 -rn | tail -n +~a | cut -f2- | while IFS= read -r archive; do rm -v -- \"$archive\" \"$archive.sha256\"; done"
                  pattern
                  (+ 1 keep-amount)))
    (if keep-days
        (list (format #f "find . -maxdepth 1 -type f -name '~a' -mtime +~a -print | while IFS= read -r archive; do rm -v -- \"$archive\" \"$archive.sha256\"; done"
                      pattern
                      keep-days))
        '())
    (list "find . -maxdepth 1 -type f \\( -name '*.tar.gz' -o -name '*.sql.gz' -o -name '*.part' \\) -mtime +1 -print -delete")
    (list (format #f "echo \"~a: $(find . -maxdepth 1 -type f -name '~a' | wc -l) archive(s) kept\""
                  pwd
                  pattern)))
   " && "))

;; ====== Timer service factory ======

(define* (make-timer-service #:key
                             name
                             schedule
                             (script #f)
                             (program #f)
                             (user "root")
                             (group "root")
                             (home "/root")
                             (requirement '(user-processes file-systems))
                             (max-duration 14400)
                             documentation)
  "Return a Shepherd service running SCRIPT, or PROGRAM, according to
SCHEDULE.

SCHEDULE is a Vixie cron string.  SCRIPT is a shell fragment executed
with bash as USER and GROUP; PROGRAM is a file-like (a `program-file',
typically) executed directly, for a job that is a Scheme program rather
than a shell script.  Exactly one of the two is expected.  Either way
HOME is set to HOME and the output is written to
/var/log/wolk-jjba/NAME.log.  The service has a `trigger' action, so it
can be run immediately with `herd trigger NAME'."
  (let ((log-file (format #f "/var/log/wolk-jjba/~a.log" name))
        ;; The environment is assembled here rather than inside the
        ;; gexp: `#$@' cannot splice a list that may be empty (Guix
        ;; refuses the empty list as a gexp input), so the whole list is
        ;; passed as one value instead of built up in the expression.
        (environment (list (string-append "HOME=" home)
                           "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin"
                           "SSL_CERT_DIR=/etc/ssl/certs"
                           "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt")))
    (shepherd-service
     (provision (list name))
     (requirement requirement)
     (documentation documentation)
     (modules '((shepherd service timer)))
     (start #~(make-timer-constructor
                (cron-string->calendar-event #$schedule)
                (command #$@(if program
                                (list program)
                                (list (file-append bash-minimal "/bin/bash")
                                      "-c"
                                      script))
                         #:user #$user
                         #:group #$group
                         #:environment-variables #$environment)
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
                              (includes '())
                              (sqlite-dbs '()))
  (make-timer-service
   #:name service-name
   #:schedule schedule
   #:script (make-backups-job #:pwd pwd
                              #:dest-dir dest-dir
                              #:name archive-name
                              #:includes includes
                              #:sqlite-dbs sqlite-dbs)
   #:documentation (format #f "Create the ~a archive." archive-name)))

(define* (make-dump-backup-service #:key
                                   service-name
                                   schedule
                                   dest-dir
                                   archive-name
                                   command
                                   suffix)
  (make-timer-service
   #:name service-name
   #:schedule schedule
   #:script (make-dump-backups-job #:dest-dir dest-dir
                                   #:name archive-name
                                   #:command command
                                   #:suffix suffix)
   #:documentation (format #f "Create the ~a dump." archive-name)))

(define* (prune-backup-service #:key
                               service-name
                               schedule
                               pwd
                               keep-amount
                               (keep-days #f))
  (make-timer-service
   #:name service-name
   #:schedule schedule
   #:script (clean-backups-job #:pwd pwd
                               #:keep-amount keep-amount
                               #:keep-days keep-days)
   #:documentation (format #f "Prune old backups in ~a." pwd)))

;; ====== Backup and prune services ======
;;
;; Every project has the same two timers: one that archives its state
;; and one that prunes the archives.  The prune timers are spread over
;; the hour so that a full backup tree is never walked twice at once,
;; and they all run after the archives of their own project are made
;; (see the README table, which this list is kept in sync with).
;;
;; The four SQLite applications pass their database through
;; #:sqlite-dbs, so the archive holds a consistent snapshot; the two
;; file-backed projects (static sites, the Torikomi media tree) are
;; tarred as they are.  PostgreSQL is dumped, not tarred.

;; Wikimusic

(define wikimusic-backup-service
  (make-backup-service
   #:service-name 'backup-wikimusic
   #:schedule "0 */12 * * *"
   #:pwd "/etc/byggsteg/job-clone/wikimusic/trunk"
   #:dest-dir "/wolk-jjba-backups/wikimusic"
   #:archive-name "wikimusic-backup"
   #:sqlite-dbs '("wikimusic.db")))

(define wikimusic-prune-service
  (prune-backup-service
   #:service-name 'prune-wikimusic
   #:schedule "15 * * * *"
   #:pwd "/wolk-jjba-backups/wikimusic"
   #:keep-amount 6
   #:keep-days 45))

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
   #:keep-amount 3
   #:keep-days 30))

;; Byggsteg

(define byggsteg-backup-service
  (make-backup-service
   #:service-name 'backup-byggsteg
   #:schedule "45 */12 * * *"
   #:pwd "/etc/byggsteg/job-clone/byggsteg/trunk"
   #:dest-dir "/wolk-jjba-backups/byggsteg"
   #:archive-name "byggsteg-backup"
   #:sqlite-dbs '("byggsteg.db")))

(define byggsteg-prune-service
  (prune-backup-service
   #:service-name 'prune-byggsteg
   #:schedule "50 * * * *"
   #:pwd "/wolk-jjba-backups/byggsteg"
   #:keep-amount 6
   #:keep-days 45))

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
   #:keep-amount 6
   #:keep-days 90))

;; LucidPlan

(define lucidplan-backup-service
  (make-backup-service
   #:service-name 'backup-lucidplan
   #:schedule "15 */12 * * *"
   #:pwd "/etc/byggsteg/job-clone/lucidplan/trunk"
   #:dest-dir "/wolk-jjba-backups/lucidplan"
   #:archive-name "lucidplan-backup"
   #:sqlite-dbs '("lucidplan.db")))

(define lucidplan-prune-service
  (prune-backup-service
   #:service-name 'prune-lucidplan
   #:schedule "25 * * * *"
   #:pwd "/wolk-jjba-backups/lucidplan"
   #:keep-amount 6
   #:keep-days 45))

;; Torikomi

(define torikomi-backup-service
  (make-backup-service
   #:service-name 'backup-torikomi
   #:schedule "30 */12 * * *"
   #:pwd "/srv"
   #:dest-dir "/wolk-jjba-backups/torikomi"
   #:archive-name "torikomi-backup"
   #:includes '("torikomi")))

(define torikomi-prune-service
  (prune-backup-service
   #:service-name 'prune-torikomi
   #:schedule "35 * * * *"
   #:pwd "/wolk-jjba-backups/torikomi"
   #:keep-amount 6
   #:keep-days 90))

;; PingWing

(define pingwing-backup-service
  (make-backup-service
   #:service-name 'backup-pingwing
   #:schedule "45 */12 * * *"
   #:pwd "/etc/byggsteg/job-clone/pingwing/trunk"
   #:dest-dir "/wolk-jjba-backups/pingwing"
   #:archive-name "pingwing-backup"
   #:sqlite-dbs '("pingwing.db")))

(define pingwing-prune-service
  (prune-backup-service
   #:service-name 'prune-pingwing
   #:schedule "55 * * * *"
   #:pwd "/wolk-jjba-backups/pingwing"
   #:keep-amount 6
   #:keep-days 45))

;; PostgreSQL
;;
;; The dump is taken with pg_dumpall, as the `postgres' role: the timer
;; itself runs as root, and peer authentication over the local socket
;; would otherwise try to authenticate a role called `root'.  pg_dumpall
;; rather than pg_dump because the applications need their roles and
;; tablespaces back too, not just tables: `--clean --if-exists' makes the
;; dump restorable into a cluster that already holds the old objects.

(define postgres-backup-service
  (make-dump-backup-service
   #:service-name 'backup-postgres
   #:schedule "30 */12 * * *"
   #:dest-dir "/wolk-jjba-backups/postgres"
   #:archive-name "postgres-backup"
   #:command "sudo -u postgres /run/current-system/profile/bin/pg_dumpall --clean --if-exists | gzip -9"
   #:suffix "sql.gz"))

(define postgres-prune-service
  (prune-backup-service
   #:service-name 'prune-postgres
   #:schedule "40 * * * *"
   #:pwd "/wolk-jjba-backups/postgres"
   #:keep-amount 6
   #:keep-days 45))

;; ====== Hetzner Storage Box mirror ======

(define backup-upload-service
  (make-timer-service
   #:name 'backup-upload
   #:schedule "58 * * * *"
   #:script "rsync -av --delete --timeout=600 --contimeout=30 --partial-dir=.rsync-partial --exclude '/archive' --exclude '.rsync-partial' /wolk-jjba-backups/ wolkenschlosslagerung:wolk-jjba-backups"
   #:user "backer-upper"
   #:group "users"
   #:home "/home/backer-upper"
   #:requirement '(user-processes file-systems networking)
   #:max-duration 14400
   #:documentation
   "Mirror /wolk-jjba-backups to the Hetzner Storage Box."))

;; ====== Application restarts ======

(define restart-app-daemons-service
  (make-timer-service
   #:name 'restart-app-daemons
   #:schedule "0 * * * *"
   #:script (string-join
             (map (lambda (daemon)
                    (format #f "herd restart ~a || true" daemon))
                  '(byggsteg-daemon lucidplan-daemon wikimusic-daemon
                                    pingwing-daemon torikomi-daemon
                                    symbanta-api-daemon))
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
    backup-postgres prune-postgres
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
        postgres-backup-service
        postgres-prune-service
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
