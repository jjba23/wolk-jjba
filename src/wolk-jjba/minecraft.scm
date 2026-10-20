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
;; Shepherd service for the Minecraft (Forge) server.
;;
;; The server is a third-party `run.sh' in /srv/games/minecraft and
;; runs as the unprivileged minecraft-daemon user.  Its stdout/stderr
;; goes to /var/log/wolk-jjba/minecraft.log so it never floods the
;; routed system log.  mcron archives /srv/games/minecraft on Sunday,
;; Tuesday and Thursday, see (wolk-jjba crons).
;;
;; Code:

(define-module (wolk-jjba minecraft)
  #:use-module (gnu)
  #:use-module (guix))

(use-service-modules shepherd)

(define-public (wolk-jjba-minecraft-server-service config)
  (list (shepherd-service (documentation "Run minecraft-server as a daemon")
                          (provision '(minecraft-server))
                          (requirement '())
                          (start #~(lambda args
                                     (mkdir-p "/var/log/wolk-jjba")
                                     ((make-forkexec-constructor '("sh" "run.sh")
                                       #:directory "/srv/games/minecraft"
                                       #:log-file "/var/log/wolk-jjba/minecraft.log"
                                       #:environment-variables (list
                                                                "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin")
                                       #:user "minecraft-daemon")
                                      args)))
                          (stop #~(make-kill-destructor))
                          (auto-start? #t)
                          (respawn? #t))))

(define-public wolk-jjba-minecraft-server-service-type
  (service-type (name 'minecraft-server)
                (description "Run minecraft-server as a daemon")
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   wolk-jjba-minecraft-server-service)))
                (default-value '())))
