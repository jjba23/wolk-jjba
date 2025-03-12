;;;; wolk-jjba

;; Copyright (C) 2025 - Josep Bigorra, jjba23 <jjbigorra@gmail.com>

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

(define-module (wolk-jjba lucidplan)
  #:use-module (gnu)
  #:use-module (guix))

(use-service-modules shepherd)

(begin
  (define lucidplan-env
    (list "GUILE_LOAD_PATH=/run/current-system/profile/share/guile/site/3.0"
     "GUILE_DBD_PATH=/run/current-system/profile/lib"
     "C_INCLUDE_PATH=/run/current-system/profile/include"
     "GUILE_LOAD_COMPILED_PATH=/run/current-system/profile/lib/guile/3.0/site-ccache:/run/current-system/profile/share/guile/site/3.0"
     "LIBRARY_PATH=/run/current-system/profile/lib"
     "GIT_SSL_NO_VERIFY=1"
     "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin"))
  (define (wolk-jjba-lucidplan-service config)
    (list (shepherd-service (documentation "Run lucidplan as a daemon")
                            (provision '(lucidplan))
                            (requirement '())
                            (start #~(make-forkexec-constructor '("make"
                                                                  "production-server")
                                      #:directory
                                      "/etc/byggsteg/job-clone/lucidplan/trunk"
                                      #:environment-variables lucidplan-env))
                            (stop #~(make-kill-destructor))
                            (auto-start? #t)
                            (respawn? #t))))
  (export wolk-jjba-lucidplan-service))

(define-public wolk-jjba-lucidplan-service-type
  (service-type (name 'lucidplan)
                (description "Run lucidplan as a daemon")
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   wolk-jjba-lucidplan-service)))
                (default-value '())))

