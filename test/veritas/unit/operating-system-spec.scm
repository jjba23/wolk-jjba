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
;; The whole point of config.scm is that it evaluates, and the failures
;; that matter are the ones that only show up at evaluation time: a
;; capability that is wired to the wrong service type, a gexp that
;; references a variable that no longer exists, a secret file that is
;; read from a path nobody creates.  So this suite evaluates the file
;; for real, in a child Guile, with WOLK_JJBA_SECRETS pointing at
;; fixtures it writes itself -- no root, and no touching /etc/secrets.
;;
;; The evaluation happens in a child process rather than by loading
;; config.scm into this module, because the file imports a large part of
;; (gnu services) and would shadow the names this suite needs.

;;; Code:

(define-module (veritas unit operating-system-spec)
  #:use-module (veritas veritas)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 format)
  #:export (spec))

(define (read-all port)
  "Return everything PORT yields as a string."
  (let loop ((lines '()))
    (let ((line (read-line port)))
      (if (eof-object? line)
          (string-concatenate-reverse lines)
          (loop (cons (string-append line "\n") lines))))))

(define (make-fixture-directory)
  "Create a directory holding the two secrets config.scm reads."
  (let* ((directory (format #f "/tmp/wolk-jjba-spec-~a-~a"
                            (getpid) (current-time)))
         (admin (format #f "~a/mpd-admin" directory))
         (read (format #f "~a/mpd-read" directory)))
    (mkdir directory)
    (call-with-output-file admin
      (lambda (port) (display "fixture-admin-password\n" port)))
    (call-with-output-file read
      (lambda (port) (display "fixture-read-password\n" port)))
    directory))

(define fixtures (make-fixture-directory))

(define (config-expression)
  "The child program: evaluate config.scm and print what it produced."
  (format #f
          "(use-modules (gnu) (guix) (gnu system locale))
(load ~s)
(write (list (operating-system? wolk-jjba-os)
             (operating-system-host-name wolk-jjba-os)
             mpd-admin-password
             mpd-read-password
             (length (operating-system-services wolk-jjba-os))
             (map locale-definition-name
                  (operating-system-locale-definitions wolk-jjba-os))))"
          (string-append (getcwd) "/config.scm")))

(define (evaluate-config secrets-directory)
  "Evaluate config.scm with WOLK_JJBA_SECRETS set to SECRETS-DIRECTORY.

Return a pair of the exit status and whatever the child printed."
  (let* ((port (open-pipe* OPEN_READ "env"
                           (format #f "WOLK_JJBA_SECRETS=~a" secrets-directory)
                           "guile" "-L" "./src" "-c" (config-expression)))
         (output (read-all port))
         (status (close-pipe port)))
    (cons status output)))

(define evaluation (evaluate-config fixtures))

(define result
  (let ((status (car evaluation))
        (output (cdr evaluation)))
    (if (zero? status)
        (with-input-from-string output read)
        '())))

(define missing-secrets-evaluation
  (evaluate-config "/tmp/wolk-jjba-spec-no-such-directory"))

(define operating-system-suite
  (suite "Operating System Suite"

         (test "The system configuration evaluates as an ordinary user"
               (assert-equal #:expect 0
                             #:got (car evaluation)
                             #:name "config.scm evaluates without root")
               (assert-equal #:expect "wolk-jjba"
                             #:got (list-ref result 1)
                             #:name "The host keeps its name")
               (assert-true (and (list-ref result 0) #t)
                            #:name "The result is an operating-system"))

         (test "The passwords come from the secrets directory the environment names"
               (assert-equal #:expect "fixture-admin-password"
                             #:got (list-ref result 2)
                             #:name "The admin password is the fixture's")
               (assert-equal #:expect "fixture-read-password"
                             #:got (list-ref result 3)
                             #:name "The read password is the fixture's"))

         (test "The machine still has its services"
               (assert-true (> (list-ref result 4) 50)
                            #:name "The service list is the whole machine"))

         (test "The languages a visitor may ask for are compiled"
               ;; A language only works when glibc has its locale: without
               ;; one, a process falls back to C and gettext transliterates
               ;; every message to "?".  These are the ones the sites
               ;; offer or are about to; the catalogs themselves live in
               ;; each application.
               (assert-equal #:expect '(#t #t #t #t #t #t)
                             #:got (map (lambda (name)
                                          (and (member name (list-ref result 5))
                                               #t))
                                        '("ja_JP.utf8" "el_GR.utf8"
                                          "zh_TW.utf8" "zh_CN.utf8"
                                          "ar_SA.utf8" "ru_RU.utf8"))
                             #:name "Japanese, Greek, Chinese (both scripts), Arabic and Russian"))

         (test "A missing secrets directory fails the evaluation"
               (assert-true (not (zero? (car missing-secrets-evaluation)))
                            #:name "config.scm cannot silently ship without secrets"))))

(define (spec)
  (veritas-run operating-system-suite))
