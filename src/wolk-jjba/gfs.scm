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
;; Grandfather-Father-Son retention for the archives that live on the
;; Hetzner Storage Box, on top of the hourly mirror.
;;
;; Two trees on the box, with two owners:
;;
;;   wolk-jjba-backups/<project>/          the mirror.  rsync --delete
;;                                        makes it an exact copy of
;;                                        /wolk-jjba-backups, whose
;;                                        prune timers keep only the
;;                                        newest handful of archives.
;;   wolk-jjba-backups/archive/<project>/ the long-term tree.  This
;;                                        script is its only owner, and
;;                                        the mirror excludes it.
;;
;; The mirror alone cannot give long-term retention -- anything the
;; local prune deletes is deleted from the box an hour later -- so this
;; job *promotes*: once a week and once a month it copies the newest
;; archive of each project into the archive tree, then prunes that tree
;; with the three classic rules:
;;
;;   son         every archive up to 7 days old
;;   father      one archive per ISO week, up to 28 days
;;   grandfather one archive per month, up to 365 days
;;   everything else is deleted
;;
;; Promotion is idempotent: it copies only when the current week or the
;; current month has no archive yet, so running the job every day (which
;; is what the Shepherd timer does) yields roughly one archive per week
;; and one per month, and running it twice in an hour changes nothing.
;;
;; The interesting part is what happens when the box is unreachable.
;; The old version of this script piped `ssh ... ls' through
;; `close-pipe' and ignored the status: a failed connection produced an
;; empty file list, an empty file list produced "nothing to delete", and
;; the job reported success while doing nothing.  Here a transport
;; failure raises, `main' exits non-zero, and the Shepherd job log says
;; so; only a *missing directory* (which `ls' reports as exit 1 or 2) is
;; treated as "no archives yet".
;;
;; Everything except the two remote adapters is pure: parsing,
;; classification and planning are ordinary functions of their
;; arguments, which is what makes test/veritas/unit/gfs-spec.scm able to
;; run the whole retention policy against an in-memory filesystem.
;;
;; Run it by hand with `maak gfs-backup' (dry run) or
;; `maak gfs-backup --apply'.  The Shepherd timer `gfs-backup' runs it
;; daily with --apply as the backer-upper user (see (wolk-jjba
;; maintenance)).
;;
;; Code:

(define-module (wolk-jjba gfs)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-19)
  #:export (%default-projects
            %gfs-marker-directory
            archive-timestamp
            archive?
            parse-archives
            week-slot
            month-slot
            age-in-days
            gfs-plan
            promotion-plan
            merge-archives
            format-report
            run-gfs!
            write-run-marker
            make-remote
            remote?
            remote-list-files
            remote-copy-file
            remote-delete-files
            remote-make-directory
            ssh-remote
            shell-quote
            run-output
            main))

;; Where the job leaves the two little files that the hourly disk
;; report turns into Prometheus metrics: the epoch of the last
;; successful apply run, and the number of long-term archives per
;; project.  The directory is created, and owned, by the radio/backup
;; activation; the job runs as an unprivileged user and cannot write
;; into node exporter's textfile directory itself.
(define %gfs-marker-directory
  "/var/lib/wolk-gfs")

(define %default-projects
  '("wikimusic" "static-sites" "lucidplan" "torikomi"
    "byggsteg" "pingwing" "postgres" "minecraft"))

;; ====== Archive names ======

;; <project>-backup-<epoch>.tar.gz.enc, and the SQL dumps
;; <project>-backup-<epoch>.sql.gz.enc.  The timestamp is the archive's
;; identity -- not its mtime, which `cp' on the Storage Box does not
;; preserve -- so everything here works from the name alone.
(define %archive-name-rx
  (make-regexp "-([0-9]+)\\.[^/]+\\.enc$"))

(define (archive-timestamp name)
  "Return the epoch second encoded in NAME, or #f when NAME is not an
archive.

The `.sha256' sidecars, a README, a partial upload: none of them end in
`.enc' with a timestamp in front, so none of them is ever a candidate
for promotion or deletion."
  (let ((match (regexp-exec %archive-name-rx name)))
    (and match
         (string->number (match:substring match 1)))))

(define (archive? name)
  "Return #t when NAME names a backup archive."
  (and (archive-timestamp name) #t))

(define (parse-archives names)
  "Return the archives in NAMES as a list of (TIMESTAMP . NAME), newest
first.  Names that are not archives are dropped."
  (sort (filter-map (lambda (name)
                      (and (archive-timestamp name)
                           (cons (archive-timestamp name) name)))
                    names)
        (lambda (a b)
          (> (car a) (car b)))))

;; ====== Time ======

(define (age-in-days now timestamp)
  "Return how many whole days TIMESTAMP is before NOW (0 when it is in
the future, which a clock skew or a box in another time zone can
produce)."
  (max 0 (quotient (- now timestamp) 86400)))

;; Weeks are grouped with an arithmetic identity rather than a date
;; format string: 1970-01-01 was a Thursday, so adding three days before
;; dividing by seven puts every Monday at the start of a group.  The
;; result is a week index that never repeats and never straddles a year
;; boundary, which `~Y-~W' (calendar year + week number) does: 30
;; December 2024 and 2 January 2025 would otherwise be two archives in
;; the same week.
(define (week-slot timestamp)
  "Return an integer that is equal for two timestamps in the same week."
  (quotient (+ (quotient timestamp 86400) 3) 7))

(define (month-slot timestamp)
  "Return a string like \"2026-10\" for TIMESTAMP."
  (date->string (time-utc->date (make-time time-utc 0 timestamp)) "~Y-~m"))

(define (week-label timestamp)
  "Return a human-readable week label for TIMESTAMP, for the report."
  (date->string (time-utc->date (make-time time-utc 0 timestamp)) "~Y-W~W"))

(define (date-label timestamp)
  "Return a human-readable date and time for TIMESTAMP, for the report."
  (date->string (time-utc->date (make-time time-utc 0 timestamp))
                "~Y-~m-~d ~H:~M"))

;; ====== The retention rules ======

(define* (gfs-plan archives #:key
                    (now (car (gettimeofday)))
                    (son-days 7)
                    (father-days 28)
                    (grandfather-days 365))
  "Return (values KEPT DELETED) for ARCHIVES, a list of (TIMESTAMP .
NAME) newest first.

KEPT is a list of (ARCHIVE REASON) where REASON is the symbol `son',
`father' or `grandfather'; DELETED is a list of archives.  Every archive
is in exactly one of the two lists, so a caller that deletes DELETED
and keeps KEPT ends up with precisely the retention policy.

The rules are applied in one pass, newest to oldest, and the week and
month slots are claimed as the pass goes: the first archive seen for a
week is the week's representative, whichever rule keeps it."
  (let loop ((rest archives)
             (weeks '())
             (months '())
             (kept '())
             (deleted '()))
    (if (null? rest)
        (values (reverse kept) (reverse deleted))
        (let* ((archive (car rest))
               (timestamp (car archive))
               (age (age-in-days now timestamp))
               (week (week-slot timestamp))
               (month (month-slot timestamp))
               (reason (cond ((<= age son-days) 'son)
                             ((and (<= age father-days)
                                   (not (memv week weeks)))
                              'father)
                             ((and (<= age grandfather-days)
                                   (not (member month months)))
                              'grandfather)
                             (else 'expired))))
          (loop (cdr rest)
                (cons week weeks)
                (cons month months)
                (if (eq? reason 'expired)
                    kept
                    (cons (list archive reason) kept))
                (if (eq? reason 'expired)
                    (cons archive deleted)
                    deleted))))))

(define* (promotion-plan mirror archive)
  "Return the archives from MIRROR that should be copied into the archive
tree.

Only the newest mirror archive is a candidate, and only while the week
or the month it belongs to has no archive in the long-term tree yet, so
a daily run produces one archive per week and one per month rather than
365 copies a year."
  (if (null? mirror)
      '()
      (let* ((newest (car mirror))
             (timestamp (car newest))
             (week (week-slot timestamp))
             (month (month-slot timestamp))
             (weeks (map (lambda (entry) (week-slot (car entry))) archive))
             (months (map (lambda (entry) (month-slot (car entry))) archive)))
        (if (or (not (memv week weeks))
                (not (member month months)))
            (list newest)
            '()))))

(define (merge-archives promotions archive)
  "Return ARCHIVE with PROMOTIONS added, newest first."
  (sort (append promotions archive)
        (lambda (a b)
          (> (car a) (car b)))))

;; ====== Reporting ======

(define (format-report port project kept deleted promotions)
  "Write the report of one project to PORT."
  (format port "~a~%" project)
  (for-each (lambda (entry)
              (let ((archive (car entry))
                    (reason (cadr entry)))
                (format port "  [KEEP]   ~a (~a) ~a~%"
                        (cdr archive)
                        (date-label (car archive))
                        (case reason
                          ((son) "son (< 7 days old)")
                          ((father) (format #f "father (week ~a)"
                                            (week-label (car archive))))
                          ((grandfather) (format #f "grandfather (month ~a)"
                                                 (month-slot (car archive))))
                          (else (symbol->string reason))))))
            kept)
  (for-each (lambda (archive)
              (format port "  [PROMOTE] ~a (~a) -> archive/~%"
                      (cdr archive)
                      (date-label (car archive))))
            promotions)
  (for-each (lambda (archive)
              (format port "  [DELETE] ~a (~a) expired~%"
                      (cdr archive)
                      (date-label (car archive))))
            deleted))

;; ====== Remotes ======
;;
;; A remote is the four things this job needs from the Storage Box:
;; list a directory, copy a file, delete files, create a directory.
;; Keeping them behind a record is what lets the test suite run the
;; whole retention policy against a hash table instead of a Hetzner
;; account.

(define-record-type <remote>
  (make-remote listing copying deleting making-directory)
  remote?
  (listing remote-listing)
  (copying remote-copying)
  (deleting remote-deleting)
  (making-directory remote-making-directory))

;; The accessors are wrapped so that callers write `(remote-list-files
;; remote directory)` rather than `((remote-listing remote) directory)`;
;; the record is an implementation detail, the four procedures below are
;; the interface the tests implement.
(define (remote-list-files remote directory)
  "Return the names in DIRECTORY on REMOTE, or the empty list when it
does not exist yet."
  ((remote-listing remote) directory))

(define (remote-copy-file remote from to)
  "Copy FROM to TO on REMOTE and return the exit status of the copy."
  ((remote-copying remote) from to))

(define (remote-delete-files remote paths)
  "Delete PATHS on REMOTE."
  ((remote-deleting remote) paths))

(define (remote-make-directory remote directory)
  "Create DIRECTORY on REMOTE, parents and all."
  ((remote-making-directory remote) directory))

(define (shell-quote text)
  "Return TEXT quoted for /bin/sh, single quotes and all."
  (string-append "'"
                 (string-join (string-split text #\') "'\\''")
                 "'"))

(define (run-output command)
  "Run COMMAND through the shell, return (values LINES EXIT-STATUS).

LINES is the list of lines the command wrote to standard output.
Standard error is left alone, which is what puts `ssh' and `ls'
complaints into the Shepherd job log instead of swallowing them."
  (let* ((port (open-input-pipe command))
         (lines (let loop ((acc '()))
                  (let ((line (read-line port)))
                    (if (eof-object? line)
                        (reverse acc)
                        (loop (cons line acc))))))
         (status (close-pipe port)))
    (values (filter (lambda (line) (not (string-null? line))) lines)
            (status:exit-val status))))

(define* (ssh-remote #:key
                     (alias "wolkenschlosslagerung")
                     (options '())
                     (list-timeout 60))
  "Return a remote that runs commands on ALIAS over SSH.

The Storage Box's SSH endpoint exposes a very small command set, so the
remote side is only ever asked to run `ls -1', `cp', `rm -f' and
`mkdir -p'.

`ls' exits 1 or 2 when the directory does not exist, and the first run
against a box has no `archive/' tree at all, so those two statuses mean
\"nothing there yet\".  Anything else -- and in particular 255, which is
what `ssh' itself returns when it cannot connect or authenticate -- is an
error, because a run that cannot see the box must not report that the
box is tidy."
  (define* (ssh command #:key quiet?)
    (format #f "timeout ~a ssh ~a ~a ~a~a"
            list-timeout
            (string-join options " ")
            alias
            (shell-quote command)
            ;; The redirection has to happen on the *client* side: the
            ;; Storage Box's restricted shell silently drops
            ;; `2>/dev/null', so a directory that does not exist yet
            ;; would print an `ls: cannot access' line into the job log
            ;; on every run.
            (if quiet? " 2>/dev/null" "")))

  (make-remote
   (lambda (directory)
     (call-with-values
         (lambda ()
           (run-output (ssh (format #f "ls -1 ~a" directory)
                            #:quiet? #t)))
       (lambda (lines status)
         (cond ((zero? status) lines)
               ((memv status '(1 2)) '())
               ((= status 124)
                (throw 'gfs-error
                      (format #f "ls timed out on the Storage Box: ~a"
                              directory)))
               ((= status 255)
                (throw 'gfs-error
                      (format #f "cannot reach the Storage Box over ssh: ~a"
                              alias)))
               (else
                (throw 'gfs-error
                      (format #f "ls failed on the Storage Box (exit ~a): ~a"
                              status directory)))))))
   (lambda (from to)
     (call-with-values
         (lambda () (run-output (ssh (format #f "cp ~a ~a" from to))))
       (lambda (output status)
         status)))
   (lambda (paths)
     (unless (null? paths)
       (call-with-values
           (lambda ()
             (run-output (ssh (format #f "rm -f ~a"
                                      (string-join paths " ")))))
         (lambda (output status)
           (unless (zero? status)
             (throw 'gfs-error
                     (format #f "rm failed on the Storage Box (exit ~a)"
                             status)))))))
   (lambda (directory)
     (call-with-values
         (lambda ()
           (run-output (ssh (format #f "mkdir -p ~a" directory))))
       (lambda (output status)
         (unless (zero? status)
           (throw 'gfs-error
                    (format #f "mkdir failed on the Storage Box (exit ~a): ~a"
                            status directory))))))))

;; ====== The run ======

(define* (run-gfs! remote #:key
                   (projects %default-projects)
                   (root "wolk-jjba-backups")
                   (apply? #t)
                   (now (car (gettimeofday)))
                   (port (current-output-port))
                   (son-days 7)
                   (father-days 28)
                   (grandfather-days 365))
  "Run the retention policy for every project on REMOTE.

Return (values COUNTS FAILURES): COUNTS is an alist of project name to
the number of archives left in the long-term tree, FAILURES is the list
of projects that could not be processed.  A failing project does not
stop the others, and it is not silently counted as a success -- the
caller turns a non-empty FAILURES into a non-zero exit status."
  (format port "--- GFS retention on ~a (dry run: ~a) ---~%"
          root
          (if apply? "no" "yes"))
  (let loop ((remaining projects)
             (counts '())
             (failures '()))
    (if (null? remaining)
        (begin
          (format port "~%Summary: ~a project(s), ~a archive(s) kept, ~a failure(s).~%"
                  (length projects)
                  (apply + (cons 0 (map cdr counts)))
                  (length failures))
          (values (reverse counts) (reverse failures)))
        (let ((project (car remaining)))
          (catch #t
            (lambda ()
              (let* ((mirror-directory (format #f "~a/~a" root project))
                     (archive-directory (format #f "~a/archive/~a" root project))
                     (mirror (parse-archives
                              (remote-list-files remote mirror-directory)))
                     (archive (parse-archives
                               (remote-list-files remote archive-directory)))
                     (promotions (promotion-plan mirror archive)))
                (when apply?
                  (for-each
                   (lambda (entry)
                     (remote-make-directory remote archive-directory)
                     (let ((source (format #f "~a/~a"
                                           mirror-directory (cdr entry)))
                           (target (format #f "~a/~a"
                                           archive-directory (cdr entry))))
                       (unless (zero? (remote-copy-file remote source target))
                         (throw 'gfs-error
                                (format #f "cannot copy ~a to the archive tree"
                                        (cdr entry))))
                       ;; The checksum is worth copying but not worth
                       ;; failing over: an archive that predates the
                       ;; sidecar is still restorable.
                       (let ((checksum-source
                              (string-append source ".sha256"))
                             (checksum-target
                              (string-append target ".sha256")))
                         (remote-copy-file remote checksum-source
                                           checksum-target))))
                   promotions))
                (let* ((archive* (merge-archives promotions archive))
                       (kept (call-with-values
                                 (lambda ()
                                   (gfs-plan archive*
                                             #:now now
                                             #:son-days son-days
                                             #:father-days father-days
                                             #:grandfather-days
                                             grandfather-days))
                               list))
                       (deleted (cadr kept))
                       (kept (car kept)))
                  (when apply?
                    (remote-delete-files
                     remote
                     (append-map
                      (lambda (entry)
                        (let ((path (format #f "~a/~a"
                                            archive-directory (cdr entry))))
                          (list path (string-append path ".sha256"))))
                      deleted)))
                  (format-report port project kept deleted promotions)
                  (loop (cdr remaining)
                        (cons (cons project (length kept)) counts)
                        failures))))
            (lambda (key . args)
              (format (current-error-port)
                      "gfs-backup: ~a failed: ~a~%"
                      project
                      (if (eq? key 'gfs-error)
                          (if (null? args) key (car args))
                          (format #f "~a ~s" key args)))
              (loop (cdr remaining) counts (cons project failures))))))))

;; ====== Markers for the metrics ======

(define (write-lines-atomically file lines)
  "Replace FILE with LINES, via a rename, so a reader never sees half of
it."
  (let* ((temporary (string-append file ".tmp"))
         (port (open-output-file temporary)))
    (for-each (lambda (line)
                (display line port)
                (newline port))
              lines)
    (close-port port)
    (rename-file temporary file)))

(define* (write-run-marker counts #:key
                           (directory %gfs-marker-directory)
                           (now (car (gettimeofday))))
  "Record in DIRECTORY that a retention run succeeded at NOW, and how
many archives each project keeps there.

These two files are what (wolk-jjba maintenance) reads when it writes
wolk_gfs_last_success_timestamp_seconds and wolk_archive_backups, which
is how \"the long-term job has not run for three days\" becomes an alert
instead of something noticed next year.  Failing to write them must not
fail the run: the archives are already safe at that point."
  (catch #t
    (lambda ()
      (write-lines-atomically (format #f "~a/last-success" directory)
                              (list (number->string now)))
      (write-lines-atomically (format #f "~a/archive-counts" directory)
                              (map (lambda (entry)
                                     (format #f "~a ~a"
                                             (car entry) (cdr entry)))
                                   counts))
      #t)
    (lambda (key . args)
      (format (current-error-port)
              "gfs-backup: warning: cannot write the run marker in ~a: ~a~%"
              directory key)
      #f)))

;; ====== Command line ======

(define %usage
  "Usage: gfs-backup [--apply] [--dry-run] [--root DIR] [--ssh ALIAS] [PROJECT...]

Grandfather-Father-Son retention for the archives on the Hetzner Storage
Box.  Promotes the newest archive of each project into
<root>/archive/<project>/ once per week and once per month, then prunes
that tree:

  son         everything up to 7 days old
  father      one archive per week, up to 28 days
  grandfather one archive per month, up to 365 days

Nothing is copied or deleted unless --apply is given; the default is a
dry run that prints the plan.  The environment variables WOLK_GFS_ROOT
and WOLK_STORAGE_BOX (the ssh alias) override the defaults.
")

(define (option-value arguments flag)
  "Return the value that follows FLAG in ARGUMENTS, or #f."
  (let loop ((rest arguments))
    (cond ((null? rest) #f)
          ((string=? (car rest) flag)
           (and (pair? (cdr rest)) (cadr rest)))
          (else (loop (cdr rest))))))

(define (positional-arguments arguments)
  "Return the arguments that are neither flags nor flag values."
  (let loop ((rest arguments) (projects '()))
    (cond ((null? rest) (reverse projects))
          ((member (car rest) '("--root" "--ssh"))
           (loop (if (pair? (cdr rest)) (cddr rest) '()) projects))
          ((string-prefix? "--" (car rest)) (loop (cdr rest) projects))
          (else (loop (cdr rest) (cons (car rest) projects))))))

(define* (main #:key (argv (command-line)) (port (current-output-port)))
  "Run the command line in ARGV and return the process exit status.

The default is a dry run, because this is the one job whose mistakes
are not recoverable: a human running it by hand should see the plan
before anything is copied or deleted.  The Shepherd timer runs the same
program with --apply baked in."
  (let* ((arguments (cdr argv))
         (help? (or (member "--help" arguments) (member "-h" arguments)))
         (apply? (and (member "--apply" arguments) #t))
         (root (or (option-value arguments "--root")
                   (getenv "WOLK_GFS_ROOT")
                   "wolk-jjba-backups"))
         (alias (or (option-value arguments "--ssh")
                    (getenv "WOLK_STORAGE_BOX")
                    "wolkenschlosslagerung"))
         (projects (positional-arguments arguments)))
    (cond
     (help?
      (display %usage port)
      (newline port)
      0)
     ((and (member "--dry-run" arguments) apply?)
      (format (current-error-port)
              "gfs-backup: --apply and --dry-run are mutually exclusive~%")
      2)
     (else
      (catch #t
        (lambda ()
          (let* ((remote (ssh-remote #:alias alias))
                 (projects (if (null? projects)
                               %default-projects
                               projects)))
            (call-with-values
                (lambda ()
                  (run-gfs! remote
                            #:projects projects
                            #:root root
                            #:apply? (and apply? #t)
                            #:port port))
              (lambda (counts failures)
                (when apply?
                  (write-run-marker counts))
                (if (null? failures)
                    0
                    (begin
                      (format (current-error-port)
                              "gfs-backup: failed project(s): ~a~%"
                              (string-join failures " "))
                      1))))))
        (lambda (key . args)
          (format (current-error-port) "gfs-backup: ~a~%"
                  (if (eq? key 'gfs-error)
                      (if (null? args) key (car args))
                      (format #f "~a ~s" key args)))
          1))))))
