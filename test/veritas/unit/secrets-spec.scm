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
;; Unit tests for (wolk-jjba secrets) and for the job in (wolk-jjba
;; containers) that runs it.
;;
;; A secrets module can be wrong in ways that stay invisible until a build
;; fails at 3 in the morning with "unauthorized: incorrect username or
;; password", so the tests pin down the three things that decide whether a
;; pull works:
;;
;;   - the bytes.  auth.json is not a format of our own: podman and docker
;;     parse it, and the `auth' value is base64 of "user:token".  A base64
;;     encoder written by hand is exactly the kind of code that gets the
;;     padding wrong, so RFC 4648's vectors are the check.
;;
;;   - the file.  It has to be 0600, owned by the account that pulls, in
;;     that account's own home -- and it must not be rewritten when it
;;     already says the right thing, because a timer that renames a file
;;     every quarter of an hour is churn nobody asked for.
;;
;;   - the wiring.  A job that is defined but not scheduled is a job that
;;     never runs, and a job that names one account logs the other one out.
;;
;; Everything runs against fixture directories and a fake passwd: the real
;; code chowns the auth file to the account that owns it, and the suite
;; runs as joe, so the fixture's "accounts" report joe's own uid and gid
;; with a home under /tmp.  Nothing here touches /etc/secrets, and nothing
;; needs root.
;;
;; Code:

(define-module (veritas unit secrets-spec)
  #:use-module (veritas veritas)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services shepherd)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba containers)
  #:use-module (wolk-jjba secrets)
  #:use-module (veritas temp)
  #:use-module (ice-9 textual-ports)
  #:export (spec))

(define (contains? haystack needle)
  "Return #t when NEEDLE occurs in HAYSTACK."
  (and (string-contains haystack needle) #t))

(define (raises? thunk)
  "Return #t when THUNK raises, #f when it returns."
  (catch #t
    (lambda ()
      (thunk)
      #f)
    (lambda arguments #t)))

;;; ====== Fixtures ======

(define token "dckr_pat_SPECTOKEN")

(define (make-fixture)
  "Create a private directory holding a secrets directory and two homes.

The root comes from (veritas temp): a fixture name that two runs can both
pick is a fixture that fails while the file is still loading, and a
secrets fixture that fails to be created is not what any of these tests
is about."
  (let ((root (make-temporary-directory "wolk-jjba-secrets-spec")))
    (mkdir (string-append root "/secrets") #o700)
    (mkdir (string-append root "/home-joe") #o700)
    (mkdir (string-append root "/home-runner") #o700)
    root))

(define (fixture-secrets root)
  (string-append root "/secrets"))

(define* (write-token! root name text #:key (trailing "\n"))
  "Write TEXT as the secret NAME, with TRAILING after it."
  (let ((path (string-append (fixture-secrets root) "/" name)))
    (call-with-output-file path
      (lambda (port)
        (display (string-append text trailing) port)))
    (chmod path #o600)
    path))

(define (fixture-user-info root)
  "Return a USER-INFO procedure naming the fixture homes.

Both accounts report this process's own uid and gid, so the chown the
module performs succeeds without root and still has to name the right
account's home."
  (lambda (user)
    (cond
     ((string=? user "joe")
      (list (getuid) (getgid) (string-append root "/home-joe")))
     ((string=? user "byggsteg-runner")
      (list (getuid) (getgid) (string-append root "/home-runner")))
     (else #f))))

(define (auth-file root account)
  "Return the auth.json path of ACCOUNT inside the fixture ROOT."
  (string-append root "/home-" account "/.config/containers/auth.json"))

(define (file-mode path)
  "Return the permission bits of PATH as a number."
  (logand (stat:perms (stat path)) #o777))

(define (file-contents path)
  (call-with-input-file path get-string-all))

(define (remove-fixture root)
  "Delete the fixture ROOT and everything in it.

Best effort: a test that failed half-way through leaves its directory
behind rather than failing a second time on the way out, and the unique
name means a leftover can never collide with the next run."
  (remove-directory-tree root))

;;; ====== The capability, read the way the service compiler reads it ======

(define capability (containers-capability))

(define (extension-towards type)
  "Return the extension of the containers service that targets TYPE."
  (find (lambda (extension)
          (eq? (service-extension-target extension) type))
        (service-type-extensions (service-kind capability))))

(define (extension-value type)
  ((service-extension-compute (extension-towards type)) '()))

(define shepherd-services (extension-value shepherd-root-service-type))
(define rotated-logs (extension-value log-rotation-service-type))

(define (service-provisioned name)
  "Return the Shepherd service provisioned as NAME."
  (find (lambda (service)
          (memq name (shepherd-service-provision service)))
        shepherd-services))

(define timer (service-provisioned 'secrets-apply))

(define (start-sexp service)
  (object->string
   (gexp->approximate-sexp (shepherd-service-start service))))

;; The argv of the program the timer runs, as text: the program-file's
;; own gexp, so the check is what the job will actually execute.
(define program-sexp
  (object->string
   (gexp->approximate-sexp (program-file-gexp secrets-apply-program))))

(define secrets-suite
  (suite "Secrets Suite"

         (test "The base64 encoder matches RFC 4648"
               ;; The padding cases are where a hand-written encoder goes
               ;; wrong, so all three are here, plus one that carries.
               (assert-equal #:expect "Zg=="
                             #:got (base64-encode-string "f")
                             #:name "One byte is padded with two =")
               (assert-equal #:expect "Zm8="
                             #:got (base64-encode-string "fo")
                             #:name "Two bytes are padded with one =")
               (assert-equal #:expect "Zm9v"
                             #:got (base64-encode-string "foo")
                             #:name "Three bytes need no padding")
               (assert-equal #:expect "Zm9vYg=="
                             #:got (base64-encode-string "foob")
                             #:name "Four bytes carry into the next group")
               (assert-equal #:expect "Zm9vYmFy"
                             #:got (base64-encode-string "foobar")
                             #:name "The full vector")
               (assert-equal #:expect ""
                             #:got (base64-encode-string "")
                             #:name "Nothing encodes to nothing")
               (assert-equal #:expect "w6k="
                             #:got (base64-encode-string "é")
                             #:name "A non-ASCII character is encoded as its UTF-8 bytes"))

         (test "auth.json is the file podman reads"
               (let ((json (registry-auth-json "docker.io" "jjba23" token)))
                 (assert-equal
                  #:expect
                  (format #f
                          "{\"auths\": {\"docker.io\": {\"auth\": \"~a\"}}}~%"
                          (base64-encode-string
                           (string-append "jjba23:" token)))
                  #:got json
                  #:name "One registry, one auth entry, base64 of user:token")
                 (assert-true (contains? json "\"auths\"")
                              #:name "The top-level key is auths")
                 (assert-true (not (contains? json token))
                              #:name "The token itself never appears in the file")))

         (test "A credential that would need JSON escaping is refused"
               ;; A username with a quote in it produces a file podman
               ;; cannot parse, and the failure looks like a wrong token --
               ;; so it is refused where it can still be explained.
               (assert-true (raises? (lambda ()
                                       (registry-auth-json "docker.io"
                                                           "jjba\"23"
                                                           token)))
                            #:name "A quote in the username is an error")
               (assert-true (raises? (lambda ()
                                       (registry-auth-json "docker.io"
                                                           "jjba\\23"
                                                           token)))
                            #:name "So is a backslash"))

         (test "A token is read from the first line, trimmed"
               (let* ((root (make-fixture))
                      (directory (fixture-secrets root)))
                 (write-token! root "spaces" "  value-with-space  ")
                 (assert-equal #:expect "value-with-space"
                               #:got (secret-token "spaces" #:directory directory)
                               #:name "Surrounding whitespace is dropped")
                 (write-token! root "empty" "" #:trailing "")
                 (assert-equal #:expect #f
                               #:got (secret-token "empty" #:directory directory)
                               #:name "An empty secret has no value")
                 (write-token! root "blank" "   ")
                 (assert-equal #:expect #f
                               #:got (secret-token "blank" #:directory directory)
                               #:name "Neither does one that is only whitespace")
                 (assert-equal #:expect #f
                               #:got (secret-token "absent" #:directory directory)
                               #:name "A missing secret is #f, not an error")
                 (remove-fixture root)))

         (test "apply-secrets writes one 0600 auth.json per account"
               (let* ((root (make-fixture))
                      (joe (auth-file root "joe"))
                      (runner (auth-file root "runner")))
                 (write-token! root "dockerhub-token" token)
                 (let ((reports (apply-secrets
                                 #:directory (fixture-secrets root)
                                 #:users '("joe" "byggsteg-runner")
                                 #:user-info (fixture-user-info root)
                                 #:port (%make-void-port "w"))))
                   (assert-equal #:expect "docker.io"
                                 #:got (assq-ref (car reports) 'registry)
                                 #:name "The report names the registry")
                   (assert-equal #:expect 'applied
                                 #:got (assq-ref (car reports) 'status)
                                 #:name "And says the credential was applied")
                   (assert-true (file-exists? joe)
                                #:name "joe has an auth file")
                   (assert-true (file-exists? runner)
                                #:name "so does byggsteg-runner")
                   (assert-equal #:expect #o600
                                 #:got (file-mode joe)
                                 #:name "The auth file is readable by its owner only")
                   (assert-equal #:expect #o700
                                 #:got (file-mode (dirname joe))
                                 #:name "and so is the directory it lives in")
                   (assert-equal #:expect (registry-auth-json "docker.io"
                                                              "jjba23"
                                                              token)
                                 #:got (file-contents joe)
                                 #:name "The file is the credential podman reads"))
                 (remove-fixture root)))

         (test "A second run rewrites nothing"
               (let* ((root (make-fixture))
                      (joe (auth-file root "joe")))
                 (write-token! root "dockerhub-token" token)
                 (apply-secrets #:directory (fixture-secrets root)
                                #:users '("joe")
                                #:user-info (fixture-user-info root)
                                #:port (%make-void-port "w"))
                 (let* ((before-inode (stat:ino (stat joe)))
                        (before-contents (file-contents joe))
                        (reports (apply-secrets
                                  #:directory (fixture-secrets root)
                                  #:users '("joe")
                                  #:user-info (fixture-user-info root)
                                  #:port (%make-void-port "w"))))
                   (assert-equal #:expect 'unchanged
                                 #:got (cdr (car (assq-ref (car reports) 'files)))
                                 #:name "The file is reported as unchanged")
                   (assert-equal #:expect before-inode
                                 #:got (stat:ino (stat joe))
                                 #:name "The file is not replaced, not even by a rename")
                   (assert-equal #:expect before-contents
                                 #:got (file-contents joe)
                                 #:name "And its contents are untouched"))
                 (remove-fixture root)))

         (test "A changed token does rewrite, atomically"
               (let* ((root (make-fixture))
                      (joe (auth-file root "joe")))
                 (write-token! root "dockerhub-token" token)
                 (apply-secrets #:directory (fixture-secrets root)
                                #:users '("joe")
                                #:user-info (fixture-user-info root)
                                #:port (%make-void-port "w"))
                 (write-token! root "dockerhub-token" "a-new-token")
                 (let ((reports (apply-secrets
                                 #:directory (fixture-secrets root)
                                 #:users '("joe")
                                 #:user-info (fixture-user-info root)
                                 #:port (%make-void-port "w"))))
                   (assert-equal #:expect 'written
                                 #:got (cdr (car (assq-ref (car reports) 'files)))
                                 #:name "A new token is written")
                   (assert-equal #:expect
                                 (registry-auth-json "docker.io"
                                                     "jjba23"
                                                     "a-new-token")
                                 #:got (file-contents joe)
                                 #:name "and the file holds the new credential")
                   (assert-true (not (file-exists? (string-append joe ".new")))
                                #:name "No temporary file is left behind"))
                 (remove-fixture root)))

         (test "A missing secret is not an error"
               (let* ((root (make-fixture))
                      (reports (apply-secrets #:directory (fixture-secrets root)
                                              #:users '("joe")
                                              #:user-info (fixture-user-info root)
                                              #:port (%make-void-port "w"))))
                 (assert-equal #:expect 'missing
                               #:got (assq-ref (car reports) 'status)
                               #:name "The registry is reported as missing")
                 (assert-equal #:expect '()
                               #:got (assq-ref (car reports) 'files)
                               #:name "and no file is claimed for it")
                 (assert-true (not (file-exists? (auth-file root "joe")))
                              #:name "Nothing is written for a secret that is not there")
                 (remove-fixture root)))

         (test "An account that does not exist is skipped, the rest are written"
               (let* ((root (make-fixture)))
                 (write-token! root "dockerhub-token" token)
                 (let ((reports (apply-secrets
                                 #:directory (fixture-secrets root)
                                 #:users '("joe" "ghost")
                                 #:user-info (fixture-user-info root)
                                 #:port (%make-void-port "w"))))
                   (assert-true (file-exists? (auth-file root "joe"))
                                #:name "joe still gets a file")
                   (assert-equal #:expect 'no-such-user
                                 #:got (cdr (cadr (assq-ref (car reports) 'files)))
                                 #:name "The unknown account is reported as such"))
                 (remove-fixture root)))

         (test "A dry run writes nothing"
               (let* ((root (make-fixture)))
                 (write-token! root "dockerhub-token" token)
                 (let ((reports (apply-secrets #:directory (fixture-secrets root)
                                               #:users '("joe")
                                               #:user-info (fixture-user-info root)
                                               #:dry-run? #t
                                               #:port (%make-void-port "w"))))
                   (assert-equal #:expect 'would-write
                                 #:got (cdr (car (assq-ref (car reports) 'files)))
                                 #:name "The dry run says what it would write")
                   (assert-true (not (file-exists? (auth-file root "joe")))
                                #:name "and writes nothing"))
                 (remove-fixture root)))

         (test "The timer is scheduled, logged and rotated"
               (assert-true (and timer #t)
                            #:name "The capability provides a secrets-apply service")
               (assert-true (contains? (start-sexp timer) "*/15 * * * *")
                            #:name "It runs every quarter of an hour")
               (assert-true (contains? (start-sexp timer) "program-file")
                            #:name "It runs the Scheme program, not a shell script")
               (assert-true (and (member "/var/log/wolk-jjba/secrets-apply.log"
                                         rotated-logs)
                                 #t)
                            #:name "Its log file is rotated with the rest")
               (assert-true (and (shepherd-service-respawn? timer) #t)
                            #:name "And it is respawned"))

         (test "The program logs in every account that builds containers"
               (for-each (lambda (user)
                           ;; The program's argv, as `write' renders it:
                           ;; ("secrets-apply" "--apply" "--user" "joe" ...)
                           (assert-true
                            (contains? program-sexp
                                       (format #f "~s ~s" "--user" user))
                            #:name (format #f "~a is passed to secrets-apply" user)))
                         podman-users)
               (assert-true (contains? program-sexp "--apply")
                            #:name "The timer applies; the dry run is for humans")
               (assert-true (contains? program-sexp "(wolk-jjba secrets)")
                            #:name "The program imports only this repository's module"))))

(define (spec)
  (veritas-run secrets-suite))
