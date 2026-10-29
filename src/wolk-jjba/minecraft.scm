;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Shepherd service for the Minecraft (Forge) server.
;;
;; The server is a third-party `run.sh' in /srv/games/minecraft and
;; runs as the unprivileged minecraft-daemon user.  Its stdout/stderr
;; goes to /var/log/wolk-jjba/minecraft.log so it never floods the
;; routed system log.  Shepherd timer jobs archive /srv/games/minecraft
;; on Sunday, Tuesday and Thursday, see (wolk-jjba jobs).
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
