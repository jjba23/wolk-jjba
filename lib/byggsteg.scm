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

(define-module (wolk-jjba byggsteg)
  #:use-module (gnu)
  #:use-module (guix))

(use-service-modules shepherd)

(define-public (wolk-jjba-byggsteg-service config)
  (list (shepherd-service (documentation "Run byggsteg as a daemon")
                          (provision '(byggsteg))
                          (requirement '())
                          (start #~(make-forkexec-constructor '("make"
                                                                "production-server")
                                    #:directory
                                    "/etc/byggsteg/job-clone/byggsteg/trunk"
                                    #:environment-variables '("GUILE_LOAD_PATH=/run/current-system/profile/share/guile/site/3.0"
                                                              "GUILE_DBD_PATH=/run/current-system/profile/lib"
                                                              "C_INCLUDE_PATH=/run/current-system/profile/include"
                                                              "GUILE_LOAD_COMPILED_PATH=/run/current-system/profile/lib/guile/3.0/site-ccache:/run/current-system/profile/share/guile/site/3.0"
                                                              "LIBRARY_PATH=/run/current-system/profile/lib"
                                                              "GIT_SSL_NO_VERIFY=1"
                                                              "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin")))
                          (stop #~(make-kill-destructor))
                          (auto-start? #t)
                          (respawn? #t))))

(define-public wolk-jjba-byggsteg-service-type
  (service-type (name 'byggsteg)
                (description "Run byggsteg as a daemon")
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   wolk-jjba-byggsteg-service)))
                (default-value '())))

