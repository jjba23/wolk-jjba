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

(define-module (wolk-jjba prelude)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (gnu services shepherd)
  #:export (byggsteg-managed-project-dir make-guile-server-shepherd-daemon))

(define* (byggsteg-managed-project-dir dir
                                       #:key (branch 'trunk))
  (format #f "/etc/byggsteg/job-clone/~a/~a" dir trunk))

(define* (make-guile-server-shepherd-daemon #:key service-name
                                            directory
                                            documentation
                                            provision
                                            (requirement '())
                                            (cmd '("make" "production-server"))
                                            (env '("GUILE_LOAD_PATH=/run/current-system/profile/share/guile/site/3.0"
                                                   "GUILE_DBD_PATH=/run/current-system/profile/lib"
                                                   "C_INCLUDE_PATH=/run/current-system/profile/include"
                                                   "GUILE_LOAD_COMPILED_PATH=/run/current-system/profile/lib/guile/3.0/site-ccache:/run/current-system/profile/share/guile/site/3.0"
                                                   "LIBRARY_PATH=/run/current-system/profile/lib"
                                                   "GIT_SSL_NO_VERIFY=1"
                                                   "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin")))
  (define (service-shepherd-daemon config)
    (list (shepherd-service (documentation documentation)
                            (provision provision)
                            (requirement requirement)
                            (start #~(make-forkexec-constructor (list #$@cmd)
                                                                #:directory #$directory
                                                                #:environment-variables
                                                                (list #$@env)))
                            (stop #~(make-kill-destructor))
                            (auto-start? #t)
                            (respawn? #t))))

  (service (service-type (name service-name)
                         (description documentation)
                         (default-value '())
                         (extensions (list (service-extension
                                            shepherd-root-service-type
                                            service-shepherd-daemon))))))

