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
;; Unit tests for (wolk-jjba gfs), the Grandfather-Father-Son retention
;; policy that runs against the Hetzner Storage Box every night.
;;
;; This is the one job in the repository whose mistakes are irreversible
;; and invisible: a wrong rule deletes an archive that nobody misses for
;; a year, and the evidence is gone with it.  So the policy is tested
;; three ways.
;;
;; First, the rules themselves, as properties rather than as golden
;; strings: every archive up to a week old survives, nothing older than
;; a year does, the surviving older archives are one per week and one
;; per month, every archive is either kept or deleted and never both,
;; and a stray file in the directory is never a candidate at all.
;;
;; Second, the *plan*: promotion copies only the newest archive, and
;; only while its week or its month is not represented yet, which is what
;; makes a daily run produce weekly and monthly archives instead of 365
;; copies a year.
;;
;; Third, the run, against a fake Storage Box that records every copy
;; and every deletion, including the case the old shell script got
;; wrong: an unreachable box must be an error, not an empty directory
;; that "nothing needs deleting".
;;
;; Nothing here talks to the network; the only real process is the
;; `sh -c' in the run-output test.
;;
;;; Code:

(define-module (veritas unit gfs-spec)
  #:use-module (veritas veritas)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-19)
  #:use-module (srfi srfi-26)
  #:use-module (wolk-jjba gfs)
  #:export (spec))

;; A fixed "now": 22 October 2026, 12:00 UTC.
(define now
  (time-second (date->time-utc (make-date 0 0 0 12 22 10 2026 0))))

(define (days-ago days)
  (- now (* days 86400)))

(define (archive-at age)
  "Return an archive that is AGE whole days old."
  (let ((timestamp (days-ago age)))
    (cons timestamp (format #f "proj-backup-~a.tar.gz.enc" timestamp))))

(define (archives-at ages)
  (sort (map archive-at ages) (lambda (a b) (> (car a) (car b)))))

(define (kept-ages kept)
  "Return the ages, in days, of the archives a plan kept."
  (map (lambda (entry) (age-in-days now (caar entry))) kept))

(define (deleted-ages deleted)
  (map (lambda (archive) (age-in-days now (car archive))) deleted))

(define (reasons kept)
  (map cadr kept))

(define (path-directory path)
  (string-join (drop-right (string-split path #\/) 1) "/"))

(define (path-base path)
  (car (take-right (string-split path #\/) 1)))

;; ====== A fake Storage Box ======

(define-record-type <fake-box>
  (make-fake-box tree copies deletions)
  fake-box?
  (tree fake-box-tree)
  (copies fake-box-copies set-fake-box-copies!)
  (deletions fake-box-deletions set-fake-box-deletions!))

(define (fake-box)
  (make-fake-box (make-hash-table) '() '()))

(define (box-put! box directory names)
  (hash-set! (fake-box-tree box) directory names))

(define (box-list box directory)
  (or (hash-ref (fake-box-tree box) directory) '()))

(define (fake-remote box)
  "Return a remote that behaves like the Storage Box, recording what it
was asked to do."
  (make-remote
   (lambda (directory)
     (box-list box directory))
   (lambda (from to)
     (set-fake-box-copies! box (cons (cons from to) (fake-box-copies box)))
     (let ((directory (path-directory to)))
       (box-put! box directory
                 (cons (path-base to) (box-list box directory))))
     0)
   (lambda (paths)
     (set-fake-box-deletions! box (append paths (fake-box-deletions box)))
     (for-each (lambda (path)
                 (let ((directory (path-directory path)))
                   (box-put! box directory
                             (delete (path-base path)
                                     (box-list box directory)))))
               paths))
   (lambda (directory)
     (unless (hash-ref (fake-box-tree box) directory)
       (box-put! box directory '())))))

(define (unreachable-remote)
  "Return a remote whose listing always fails, the way an ssh that cannot
connect fails."
  (make-remote
   (lambda (directory)
     (error "cannot reach the Storage Box over ssh"))
   (lambda (from to) 1)
   (lambda (paths) #f)
   (lambda (directory) #f)))

;; ====== The suite ======

(define gfs-suite
  (suite "GFS Retention Suite"

         (test "Archive names identify an archive; sidecars and strays do not"
               (assert-equal #:expect 1700000000
                             #:got (archive-timestamp
                                    "wikimusic-backup-1700000000.tar.gz.enc")
                             #:name "A tar archive carries its timestamp")
               (assert-equal #:expect 1700000000
                             #:got (archive-timestamp
                                    "postgres-backup-1700000000.sql.gz.enc")
                             #:name "So does an SQL dump")
               (assert-equal #:expect #f
                             #:got (archive-timestamp
                                    "wikimusic-backup-1700000000.tar.gz.enc.sha256")
                             #:name "The checksum sidecar is not an archive")
               (assert-equal #:expect #f
                             #:got (archive-timestamp "README")
                             #:name "A stray file is not an archive")
               (assert-equal #:expect #f
                             #:got (archive-timestamp
                                    "wikimusic-backup-1700000000.tar.gz")
                             #:name "An unencrypted tarball is not an archive"))

         (test "Parsing sorts newest first and drops everything else"
               (assert-equal #:expect (list 300 200 100)
                             #:got (map car (parse-archives
                                            (list "p-backup-100.tar.gz.enc"
                                                  "README"
                                                  "p-backup-300.tar.gz.enc"
                                                  "p-backup-200.tar.gz.enc"
                                                  "p-backup-200.tar.gz.enc.sha256")))
                             #:name "Newest first, strays ignored")
               (assert-equal #:expect '()
                             #:got (parse-archives '())
                             #:name "An empty directory parses to nothing"))

         (test "Every archive up to a week old survives"
               (let ((plan (call-with-values
                               (lambda ()
                                 (gfs-plan (archives-at (iota 8)) #:now now))
                             list)))
                 (assert-equal #:expect (iota 8)
                               #:got (sort (kept-ages (car plan)) <)
                               #:name "Ages 0 to 7 are all kept")
                 (assert-equal #:expect '()
                               #:got (cadr plan)
                               #:name "Nothing in the son window is deleted")
                 (assert-true (and (every (cut eq? 'son <>)
                                          (reasons (car plan)))
                                   #t)
                              #:name "All of them are kept as son")))

         (test "Past a week, the week's representative survives"
               (let* ((ages (list 0 8 9 10 11 12 13 14 20 27))
                      (plan (call-with-values
                                (lambda ()
                                  (gfs-plan (archives-at ages) #:now now))
                              list))
                      (kept (car plan))
                      (deleted (cadr plan))
                      (kept-weeks (map (lambda (entry)
                                         (week-slot (caar entry)))
                                       kept))
                      (deleted-weeks (map (lambda (archive)
                                            (week-slot (car archive)))
                                          deleted)))
                 (assert-equal #:expect (length kept-weeks)
                               #:got (length (delete-duplicates kept-weeks))
                               #:name "No week is represented twice")
                 (assert-true (and (every (lambda (week)
                                            (and (memv week kept-weeks) #t))
                                          deleted-weeks)
                                   #t)
                              #:name "A deleted archive's week is kept by another")
                 (assert-true (and (every (cut eq? 'father <>)
                                          (reasons (filter (lambda (entry)
                                                             (> (age-in-days now (caar entry)) 7))
                                                           kept)))
                                   #t)
                              #:name "Those survivors are father archives")))

         (test "Past a month, the month's representative survives"
               (let* ((ages (list 40 45 50 80 85 120 200 300 360))
                      (plan (call-with-values
                                (lambda ()
                                  (gfs-plan (archives-at ages) #:now now))
                              list))
                      (kept (car plan))
                      (deleted (cadr plan))
                      (kept-months (map (lambda (entry)
                                          (month-slot (caar entry)))
                                        kept))
                      (deleted-months (map (lambda (archive)
                                             (month-slot (car archive)))
                                           deleted)))
                 (assert-equal #:expect (length kept-months)
                               #:got (length (delete-duplicates kept-months))
                               #:name "No month is represented twice")
                 (assert-true (and (every (lambda (month)
                                            (and (member month kept-months) #t))
                                          deleted-months)
                                   #t)
                              #:name "A deleted archive's month is kept by another")
                 (assert-true (and (every (cut eq? 'grandfather <>)
                                          (reasons kept))
                                   #t)
                              #:name "Those survivors are grandfather archives")))

         (test "Nothing older than a year survives, and a year is honoured"
               (let ((plan (call-with-values
                               (lambda ()
                                 (gfs-plan (archives-at (list 364 365 366 400))
                                           #:now now))
                             list)))
                 (assert-equal #:expect '(364)
                               #:got (kept-ages (car plan))
                               #:name "364 days old is still kept")
                 (assert-equal #:expect '(365 366 400)
                               #:got (sort (deleted-ages (cadr plan)) <)
                               #:name "365 days and older are deleted (same month)"))
               (let ((plan (call-with-values
                               (lambda ()
                                 (gfs-plan (archives-at (list 300 366))
                                           #:now now))
                             list)))
                 (assert-equal #:expect '(300)
                               #:got (kept-ages (car plan))
                               #:name "A year-old archive in another month is kept")))

         (test "Every archive is kept or deleted, never both"
               (let* ((ages (iota 40 0 9))
                      (archives (archives-at ages))
                      (plan (call-with-values
                                (lambda () (gfs-plan archives #:now now))
                              list))
                      (kept (map car (car plan)))
                      (deleted (cadr plan)))
                 (assert-equal #:expect (length archives)
                               #:got (+ (length kept) (length deleted))
                               #:name "The two lists partition the directory")
                 (assert-equal #:expect '()
                               #:got (lset-intersection equal? kept deleted)
                               #:name "No archive appears in both")
                 (assert-true (and (every (lambda (archive)
                                            (> (car archive) (days-ago 365)))
                                          kept)
                                   #t)
                              #:name "Nothing kept is over a year old")))

         (test "Promotion is once per week and once per month"
               (let* ((newest (archive-at 1))
                      (other (archive-at 20)))
                 (assert-equal #:expect (list newest)
                               #:got (promotion-plan (list newest) '())
                               #:name "An empty archive tree takes the newest")
                 (assert-equal #:expect '()
                               #:got (promotion-plan (list newest)
                                                     (list (archive-at 2)))
                               #:name "A week that is already represented needs no copy")
                 (assert-equal #:expect (list newest)
                               #:got (promotion-plan (list newest)
                                                     (list other))
                               #:name "A month that is already represented still takes a new week")))

         (test "A run promotes, prunes and reports"
               (let* ((box (fake-box))
                      (remote (fake-remote box))
                      (project "proj")
                      (mirror (format #f "wolk-jjba-backups/~a" project))
                      (archive (format #f "wolk-jjba-backups/archive/~a" project))
                      (expired (archive-at 400))
                      (recent (archives-at (iota 6 0 2))))
                 (for-each (lambda (entry)
                             (box-put! box mirror
                                       (cons (cdr entry) (box-list box mirror))))
                           recent)
                 (box-put! box archive (list (cdr expired) "README"))
                 (let ((counts (call-with-values
                                   (lambda ()
                                     (run-gfs! remote
                                               #:projects (list project)
                                               #:apply? #t
                                               #:now now
                                               #:port (%make-void-port "w")))
                                 (lambda (counts failures)
                                   counts))))
                   (assert-equal #:expect (list (cons project 1))
                                 #:got counts
                                 #:name "One long-term archive per project")
                   (assert-true (and (member (cdr (car recent))
                                             (box-list box archive))
                                     #t)
                                #:name "The newest mirror archive was promoted")
                   (assert-true (and (member "README" (box-list box archive)) #t)
                                #:name "A stray file in the archive tree survives")
                   (assert-equal #:expect #f
                                 #:got (member (cdr expired) (box-list box archive))
                                 #:name "The expired archive was deleted")
                   (assert-true (and (every (lambda (path)
                                              (and (string-contains
                                                    path
                                                    (string-append
                                                     "archive/" project))
                                                   #t))
                                            (fake-box-deletions box))
                                     #t)
                                #:name "Nothing outside the archive tree is deleted")
                   (assert-true (not (member (cdr (car recent))
                                             (fake-box-deletions box)))
                                #:name "The promoted archive is not then deleted"))))

         (test "A dry run reports without touching the box"
               (let* ((box (fake-box))
                      (remote (fake-remote box))
                      (project "proj"))
                 (box-put! box (format #f "wolk-jjba-backups/~a" project)
                           (map cdr (archives-at '(0 400))))
                 (box-put! box (format #f "wolk-jjba-backups/archive/~a" project)
                           '())
                 (run-gfs! remote
                           #:projects (list project)
                           #:apply? #f
                           #:now now
                           #:port (%make-void-port "w"))
                 (assert-equal #:expect '()
                               #:got (fake-box-copies box)
                               #:name "No copy in a dry run")
                 (assert-equal #:expect '()
                               #:got (fake-box-deletions box)
                               #:name "No deletion in a dry run")))

         (test "A run twice in a row changes nothing the second time"
               (let* ((box (fake-box))
                      (remote (fake-remote box))
                      (project "proj")
                      (mirror (format #f "wolk-jjba-backups/~a" project))
                      (archive (format #f "wolk-jjba-backups/archive/~a" project)))
                 (box-put! box mirror (map cdr (archives-at '(0 12 24))))
                 (run-gfs! remote #:projects (list project) #:apply? #t
                           #:now now #:port (%make-void-port "w"))
                 (let ((after-first (length (box-list box archive)))
                       (copies-after-first (length (fake-box-copies box))))
                   (run-gfs! remote #:projects (list project) #:apply? #t
                             #:now now #:port (%make-void-port "w"))
                   (assert-equal #:expect after-first
                                 #:got (length (box-list box archive))
                                 #:name "The archive tree did not grow")
                   (assert-equal #:expect copies-after-first
                                 #:got (length (fake-box-copies box))
                                 #:name "The second run copied nothing"))))

         (test "An unreachable box is a failure, not an empty directory"
               (let ((counts (call-with-values
                                 (lambda ()
                                   (run-gfs! (unreachable-remote)
                                             #:projects (list "proj" "other")
                                             #:apply? #t
                                             #:now now
                                             #:port (%make-void-port "w")))
                               list)))
                 (assert-equal #:expect '()
                               #:got (car counts)
                               #:name "No project is reported as counted")
                 (assert-equal #:expect '("proj" "other")
                               #:got (cadr counts)
                               #:name "Every unreachable project is reported")
                 (assert-true (pair? (cadr counts))
                              #:name "A silent empty directory would leave this empty")))

         (test "Shell quoting survives an apostrophe"
               (assert-equal #:expect "'it'\\''s'"
                             #:got (shell-quote "it's")
                             #:name "A quote is escaped the POSIX way")
               (assert-equal #:expect "'ls -1 /a b'"
                             #:got (shell-quote "ls -1 /a b")
                             #:name "Spaces stay inside one word"))

         (test "Running a command returns its lines and its exit status"
               (call-with-values
                   (lambda () (run-output "printf 'one\ntwo\n'; exit 3"))
                 (lambda (lines status)
                   (assert-equal #:expect '("one" "two")
                                 #:got lines
                                 #:name "The output is read line by line")
                   (assert-equal #:expect 3
                                 #:got status
                                 #:name "The exit status is not swallowed"))))))

(define (spec)
  (veritas-run gfs-suite))
