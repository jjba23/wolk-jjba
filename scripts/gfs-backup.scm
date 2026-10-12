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

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 regex)
             (ice-9 format)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-19))

(define remote-dirs
  '("wolk-jjba-backups/byggsteg" "wolk-jjba-backups/pingwing"
    "wolk-jjba-backups/torikomi"
    "wolk-jjba-backups/lucidplan"
    "wolk-jjba-backups/wikimusic"
    "wolk-jjba-backups/static-sites"
    "wolk-jjba-backups/minecraft"))

;; Dry-run by default: pass `--apply' on the command line to actually
;; erase expired backups.  Example (see the `gfs-backup' maak task):
;;   guile -L ./src ./scripts/gfs-backup.scm --apply
(define dry-run?
  (not (member "--apply" (cdr (command-line)))))

(define son-days
  7)
(define father-days
  28)
(define grandfather-days
  365)

(define current-ts
  (time-second (current-time time-utc)))

;; Connect via SSH and pull file tokens for a specific directory path
(define (get-remote-file-tokens remote-dir)
  (let* ((cmd (format #f "ssh wolkenschlosslagerung \"ls ~a\"" remote-dir))
         (pipe (open-input-pipe cmd)))
    (let loop
      ((line (read-line pipe))
       (tokens '()))
      (if (eof-object? line)
          (begin
            (close-pipe pipe)
            (reverse tokens))
          (loop (read-line pipe)
                (fold cons tokens
                      (string-tokenize line)))))))

;; Match files containing a trailing timestamp and sort them descending (newest first)
(define (parse-and-sort-backups tokens)
  (let* ((backup-rx (make-regexp "-([0-9]+)\\.tar\\.gz\\.enc$"))
         (matched-files (filter-map (lambda (token)
                                      (let ((m (regexp-exec backup-rx token)))
                                        (if m
                                            (list (string->number (match:substring
                                                                   m 1)) token)
                                            #f))) tokens)))
    (sort matched-files
          (lambda (a b)
            (> (car a)
               (car b))))))

;; Evaluates an individual backup file against GFS thresholds and prints status
;; Returns the full path string if slated for deletion, otherwise #f to keep
(define (evaluate-and-report-file! item remote-dir weeks-hash months-hash)
  (let* ((file-ts (car item))
         (filename (cadr item))
         (full-path (format #f "~a/~a" remote-dir filename))

         ;; Time Math
         (age-seconds (- current-ts file-ts))
         (age-days (quotient age-seconds 86400))

         ;; Date Formats (SRFI-19)
         (file-time (make-time time-utc 0 file-ts))
         (file-date-obj (time-utc->date file-time))
         (file-date-str (date->string file-date-obj "~Y-~m-~d ~H:~M:~S"))
         (year-month (date->string file-date-obj "~Y-~m"))
         (year-week (date->string file-date-obj "~Y-~W"))

         ;; GFS Rules Evaluation
         (is-son? (<= age-days son-days))
         (fills-week? (and (<= age-days father-days)
                           (not (hash-ref weeks-hash year-week))))
         (fills-month? (and (<= age-days grandfather-days)
                            (not (hash-ref months-hash year-month))))

         (keep? (or is-son? fills-week? fills-month?))
         (reason (cond
                   (is-son? "Son (<= 7 days old)")
                   (fills-week? (format #f "Father (Weekly slot: ~a)"
                                        year-week))
                   (fills-month? (format #f "Grandfather (Monthly slot: ~a)"
                                         year-month))
                   (else ""))))

    ;; Commit timeline status updates statefully
    (when (and (<= age-days father-days)
               (not (hash-ref weeks-hash year-week)))
      (hash-set! weeks-hash year-week #t))
    (when (and (<= age-days grandfather-days)
               (not (hash-ref months-hash year-month)))
      (hash-set! months-hash year-month #t))

    ;; Print item report line
    (if keep?
        (format #t "[KEEP]   ~40a (~a) -> ~a\n" filename file-date-str reason)
        (format #t "[DELETE] ~40a (~a) -> Expired\n" filename file-date-str))

    ;; Return path if it needs to go to the deletion list
    (if keep? #f full-path)))

;; Dispatches batch file deletions to the remote target if dry-run is disabled
(define (execute-remote-deletions! files-to-delete)
  (if (not (null? files-to-delete))
      (begin
        (format #t "
Total files marked for erasure in this directory: ~a
"
                (length files-to-delete))
        (if (not dry-run?)
            (begin
              (display "Executing batch remote deletions via plain rm...
")
              (let* ((paths-str (string-join (map (lambda (p)
                                                    (format #f "'~a'" p))
                                                  files-to-delete) " "))
                     (rm-cmd (format #f
                                     "ssh wolkenschlosslagerung \"rm -f ~a\""
                                     paths-str)))
                (system rm-cmd)
                (display "Remote pruning complete.\n")))
            (display
             "Dry run active. No remote files were physically modified.
")))
      (display "
No files need to be deleted in this directory.
")))

;; Orchestrates the logic chain for an individual backup directory target
(define (process-directory! remote-dir)
  (format #t "
==================================================
")
  (format #t " PROCESSING TARGET: ~a\n" remote-dir)
  (format #t "==================================================
")

  ;; Isolated tracking tables per target folder execution loop
  (let ((weeks (make-hash-table))
        (months (make-hash-table))
        (tokens (get-remote-file-tokens remote-dir)))
    (let ((backups (parse-and-sort-backups tokens)))
      (if (null? backups)
          (display "No matching backup configurations located here.
")
          (let loop
            ((remaining backups)
             (to-delete '()))
            (if (null? remaining)
                (execute-remote-deletions! to-delete)
                (let* ((item (car remaining))
                       (delete-path? (evaluate-and-report-file! item
                                                                remote-dir
                                                                weeks months)))
                  (loop (cdr remaining)
                        (if delete-path?
                            (cons delete-path? to-delete) to-delete)))))))))

;; --- MAIN ENTRY POINT ---

(define (main)
  (format #t "--- WOLKENSCHLOSSLAGERUNG GFS ROTATION REPORT (DRY_RUN=~a) ---
"
          dry-run?)
  (display "Connecting to Hetzner Storage Box...\n")
  (for-each process-directory! remote-dirs)
  (display "
All directory targets processed successfully.
"))

(main)
