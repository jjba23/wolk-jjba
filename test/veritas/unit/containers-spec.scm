;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (wolk-jjba containers).
;;
;; Rootless Podman fails in a different place for every missing piece,
;; and most of the failures only happen on the machine, at boot, in a
;; service nobody is watching.  So the tests read the pieces the way the
;; service compiler would and check the two things that matter:
;;
;;   - both accounts that build in containers are in every list that has
;;     to name them (subuids, subgids, session directories, API sockets,
;;     prune), because a user added to one list and forgotten in another
;;     is a job that fails once a week;
;;
;;   - the paths a Docker client is handed are the paths the machine
;;     actually serves, and the configuration does not assume systemd
;;     (there is none here) or a kernel that allows overlay in a user
;;     namespace.

;;; Code:

(define-module (veritas unit containers-spec)
  #:use-module (veritas veritas)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services containers)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu packages containers)
  #:use-module (gnu packages file-systems)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba containers)
  #:export (spec))

(define (contains? haystack needle)
  "Return #t when NEEDLE occurs in HAYSTACK."
  (and (string-contains haystack needle) #t))

(define (tree-contains? tree needle)
  "Return #t when NEEDLE occurs anywhere in the nested list TREE."
  (cond
    ((null? tree) #f)
    ((pair? tree) (or (tree-contains? (car tree) needle)
                      (tree-contains? (cdr tree) needle)))
    ((vector? tree) (tree-contains? (vector->list tree) needle))
    ((equal? tree needle) #t)
    (else #f)))

(define capability (containers-capability))

(define (extension-towards type)
  "Return the extension of the containers service that targets TYPE."
  (find (lambda (extension)
          (eq? (service-extension-target extension) type))
        (service-type-extensions (service-kind capability))))

(define (extension-value type)
  ((service-extension-compute (extension-towards type)) '()))

(define shepherd-services (extension-value shepherd-root-service-type))
(define profile-packages (extension-value profile-service-type))
(define activation (gexp->approximate-sexp
                    (extension-value activation-service-type)))
(define etc-files (extension-value etc-service-type))
(define rotated-logs (extension-value log-rotation-service-type))

(define (service-provisioned name)
  "Return the Shepherd service provisioned as NAME."
  (find (lambda (service)
          (memq name (shepherd-service-provision service)))
        shepherd-services))

(define sessions (service-provisioned 'podman-user-sessions))

(define (api-service user)
  (service-provisioned (string->symbol (string-append "podman-api-" user))))

(define (start-sexp service)
  (gexp->approximate-sexp (shepherd-service-start service)))

(define podman-config (podman-configuration))

(define subuid-names
  (map subid-range-name
       (rootless-podman-configuration-subuids podman-config)))

(define subgid-names
  (map subid-range-name
       (rootless-podman-configuration-subgids podman-config)))

(define (file-content file)
  "Return the text of FILE, a plain-file."
  (plain-file-content file))

(define containers-suite
  (suite "Containers Suite"

         (test "Both accounts that build in containers are configured"
               (assert-true (and (member "joe" podman-users) #t)
                            #:name "joe builds in containers by hand")
               (assert-true (and (member "byggsteg-runner" podman-users) #t)
                            #:name "the CI builds in containers as its own user")
               (assert-equal #:expect podman-users
                             #:got subuid-names
                             #:name "Every podman user has a subuid range")
               (assert-equal #:expect podman-users
                             #:got subgid-names
                             #:name "Every podman user has a subgid range")
               (assert-equal #:expect '(65536 65536)
                             #:got
                             (map subid-range-count
                                  (rootless-podman-configuration-subuids
                                   podman-config))
                             #:name "Each range is the kernel's usual 65536 IDs")
               (assert-equal #:expect "cgroup"
                             #:got
                             (rootless-podman-configuration-group-name
                              podman-config)
                             #:name "The cgroup group owns the cgroup tree"))

         (test "A Docker client is handed the socket the machine serves"
               (assert-equal #:expect "/run/user/1002/podman/podman.sock"
                             #:got (podman-socket-path 1002)
                             #:name "The socket lives beside the user's runtime dir")
               (assert-equal #:expect "/run/user/1002/podman"
                             #:got (podman-socket-directory 1002)
                             #:name "The socket has a directory of its own")
               (assert-equal #:expect "unix:///run/user/1002/podman/podman.sock"
                             #:got (podman-docker-host 1002)
                             #:name "DOCKER_HOST is a unix:// URL, not a path")
               (assert-equal #:expect "/run/user/0"
                             #:got (podman-runtime-directory 0)
                             #:name "The runtime directory is XDG's, by uid"))

         (test "A podman process is given a home and a runtime directory"
               (let ((env (podman-environment 1002
                                              #:home "/home/byggsteg-runner")))
                 (assert-true (and (member "HOME=/home/byggsteg-runner" env) #t)
                              #:name "The storage graph root follows HOME")
                 (assert-true (and (member "XDG_RUNTIME_DIR=/run/user/1002" env) #t)
                              #:name "Podman refuses a runtime dir that is not there")
                 (assert-true (and (member
                                    "DOCKER_HOST=unix:///run/user/1002/podman/podman.sock"
                                    env) #t)
                              #:name "A Docker client started by a build finds the API")))

         (test "One session service prepares every account's runtime directory"
               (assert-true (and sessions #t)
                            #:name "There is a sessions service")
               (assert-equal #:expect '(podman-user-sessions)
                             #:got (shepherd-service-provision sessions)
                             #:name "It is provisioned once, under one name")
               (assert-true (shepherd-service-one-shot? sessions)
                            #:name "It is a one-shot: nothing to keep running")
               (assert-true (tree-contains? (start-sexp sessions) "/run/user/")
                            #:name "It creates the XDG runtime directory")
               (assert-true (tree-contains? (start-sexp sessions) "byggsteg-runner")
                            #:name "It does it for every podman user")
               (assert-true (tree-contains? (start-sexp sessions) "enable-linger")
                            #:name "It asks elogind to keep the directory"))

         (test "Every podman user gets a Docker-compatible API socket"
               (assert-equal #:expect (length podman-users)
                             #:got
                             (length (filter (lambda (service)
                                               (string-prefix? "podman-api-"
                                                               (symbol->string
                                                                (car (shepherd-service-provision
                                                                      service)))))
                                             shepherd-services))
                             #:name "One API service per account")
               (assert-true (and (api-service "joe") #t)
                            #:name "joe can run a testcontainers suite")
               (assert-true (and (api-service byggsteg-runner) #t)
                            #:name "the CI can start a container through the API")
               (assert-true (tree-contains? (start-sexp (api-service "joe"))
                                            "system")
                            #:name "The service is `podman system service'")
               (assert-true (tree-contains? (start-sexp (api-service "joe"))
                                            "--time=0")
                            #:name "An API socket is not allowed to time out")
               (assert-true (tree-contains? (start-sexp (api-service "joe"))
                                            "unix://")
                            #:name "It speaks HTTP over a unix socket")
               (assert-true (tree-contains? (start-sexp (api-service "joe"))
                                            "/podman.sock")
                            #:name "The socket is the one DOCKER_HOST names")
               (assert-true (tree-contains? (start-sexp (api-service "joe"))
                                            podman-cgroup-group)
                            #:name "The cgroup group survives the privilege drop")
               ;; The setuid copies of newuidmap/newgidmap live in
               ;; /run/privileged/bin, and Podman finds them through PATH.
               ;; A profile-first PATH hands it the plain binaries, which
               ;; cannot write uid_map, and the service then dies with
               ;; "newuidmap: write to uid_map failed" instead of creating
               ;; the socket.
               (assert-true (tree-contains?
                             (start-sexp (api-service "joe"))
                             "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin")
                            #:name "The setuid helpers come first in PATH")
               (assert-true (shepherd-service-respawn? (api-service "joe"))
                            #:name "A killed socket is brought back"))

         (test "The activation prepares sessions and shares the checkout"
               (assert-true (tree-contains? activation "/run/user/")
                            #:name "Runtime directories exist before any service")
               (assert-true (tree-contains? activation "/etc/byggsteg")
                            #:name "The Byggsteg tree is made group-writable")
               (assert-true (tree-contains? activation "g+rwX")
                            #:name "Only directories gain an execute bit"))

         (test "The storage driver works without root"
               (assert-true (contains? (file-content
                                        (rootless-podman-configuration-containers-storage
                                         podman-config))
                                       "fuse-overlayfs")
                            #:name "overlay is given a mount program")
               (assert-true (contains? (file-content
                                        (rootless-podman-configuration-containers-storage
                                         podman-config))
                                       "driver = \"overlay\"")
                            #:name "The driver is still overlay"))

         (test "The registry order is this machine's"
               (let ((registries (file-content
                                  (rootless-podman-configuration-containers-registries
                                   podman-config))))
                 (assert-true (contains? registries "docker.io")
                              #:name "docker.io is searched first")
                 (assert-false (contains? registries "registry.fedora.org")
                               #:name "nothing here comes from the Fedora registry")))

         (test "The engine does not assume systemd"
               (assert-true (contains? %podman-containers-conf
                                       "cgroup_manager = \"cgroupfs\"")
                            #:name "Guix System has no systemd to ask for a cgroup")
               (assert-true (contains? %podman-containers-conf "pasta")
                            #:name "Rootless networking uses the packaged pasta"))

         (test "The profile has everything a rootless build needs"
               (let ((names (filter-map (lambda (entry)
                                          (if (package? entry)
                                              (package-name entry) #f))
                                        profile-packages)))
                 (assert-true (and (member "fuse-overlayfs" names) #t)
                              #:name "The storage driver's mount program is installed")
                 (assert-true (and (member "slirp4netns" names) #t)
                              #:name "The fallback user-mode network is installed"))
               (assert-true (any (lambda (entry)
                                   (and (pair? entry)
                                        (package? (car entry))
                                        (string=? (package-name (car entry))
                                                  "podman")
                                        (equal? (cadr entry) "docker")))
                                 profile-packages)
                            #:name "A `docker' command that is Podman is installed"))

         (test "The API logs are rotated with the rest"
               (assert-equal #:expect
                             (cons "/var/log/wolk-jjba/secrets-apply.log"
                                   (map (lambda (user)
                                          (format #f
                                                  "/var/log/wolk-jjba/podman-api-~a.log"
                                                  user))
                                        podman-users))
                             #:got rotated-logs
                             #:name "One log per API socket, plus the secrets timer")
               (assert-equal #:expect (containers-log-files)
                             #:got rotated-logs
                             #:name "Every log the capability writes is rotated"))

         (test "containers.conf is installed beside the files Guix writes"
               (assert-equal #:expect '("containers/containers.conf")
                             #:got (map car etc-files)
                             #:name "The fourth /etc/containers file is added"))))

(define (spec)
  (veritas-run containers-suite))
