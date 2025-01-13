;;;; wolk-jjba

;; Copyright (C) 2024 Josep Jesus Bigorra Algaba

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

(define-module (wolk-jjba wikimusic)
  #:use-module (gnu)
  #:use-module (guix))

(use-service-modules shepherd)

(define (wolk-jjba-wikimusic-ssr-service config)
  (list (shepherd-service (documentation "Run WikiMusic SSR as a daemon")
                          (provision '(wikimusic-ssr))
                          (requirement '())
                          (start #~(make-forkexec-constructor '("make"
                                                                "server")
                                                              #:directory
                                                              "/var/log/byggsteg/job-clone/wikimusic-ssr/trunk"
                                                              #:environment-variables (list
                                                                                       "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin"
                                                                                       "GIT_SSL_NO_VERIFY=1"
                                                                                       "LANG=nl_NL.UTF-8")))
                          (stop #~(make-kill-destructor))
                          (auto-start? #t)
                          (respawn? #t))))

(define wolk-jjba-wikimusic-ssr-service-type
  (service-type (name 'wikimusic-ssr)
                (description "Run WikiMusic SSR as a daemon")
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   wolk-jjba-wikimusic-ssr-service)))
                (default-value '())))

(define (wolk-jjba-wikimusic-api-service config)
  (list (shepherd-service (documentation "Run wikimusic-api as a daemon")
                          (provision '(wikimusic-api))
                          (requirement '())
                          (start #~(make-forkexec-constructor '("make"
                                                                "server")
                                                              #:directory
                                                              "/var/log/byggsteg/job-clone/wikimusic-api/trunk"
                                                              #:environment-variables (list
                                                                                       "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin"
                                                                                       "GIT_SSL_NO_VERIFY=1"
                                                                                       "LANG=nl_NL.UTF-8")))
                          (stop #~(make-kill-destructor))
                          (auto-start? #t)
                          (respawn? #t))))

(define wolk-jjba-wikimusic-api-service-type
  (service-type (name 'wikimusic-api)
                (description "Run wikimusic-api as a daemon")
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   wolk-jjba-wikimusic-api-service)))
                (default-value '())))
