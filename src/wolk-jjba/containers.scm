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
;; Rootless Podman for the two accounts that need it.
;;
;; Podman is the only container runtime on this host, and it is used by
;; two different kinds of process:
;;
;;   joe             an ordinary login, for hacking on a project locally
;;                   and for running the test suite of an application
;;                   that talks to a database or a queue in a container;
;;
;;   byggsteg-runner no login at all: Byggsteg's builds run in containers
;;                   as this user, so that a job never has to be root to
;;                   build an image or start a service in one.
;;
;; Rootless Podman has five separate pieces, and each of them fails in
;; its own way when it is missing.  This module provides all five, once,
;; for both users:
;;
;;   1. a subuid and a subgid range (/etc/subuid, /etc/subgid), without
;;      which `podman run' stops with "cannot set up namespace" -- Guix's
;;      `rootless-podman-service-type' writes them;
;;
;;   2. /sys/fs/cgroup owned by the `cgroup' group, and the controllers
;;      that rootless containers want delegated to it -- the same Guix
;;      service, which is why both accounts are in that group;
;;
;;   3. a storage driver that works without root.  Guix's default is
;;      `overlay', and rootless overlay needs either a kernel that
;;      allows it in a user namespace or `fuse-overlayfs' as its mount
;;      program; the configuration below names the latter, and the
;;      package is installed, so the driver works on any kernel;
;;
;;   4. an XDG_RUNTIME_DIR that exists.  A login session gets one from
;;      elogind; a Shepherd daemon does not, because nobody ever logs
;;      in as it.  Without it Podman fails with
;;      "cannot access /run/user/<uid>", so the activation and the
;;      per-user service below create the directory at boot and ask
;;      elogind to keep it (linger);
;;
;;   5. a Docker-compatible API socket, which is what testcontainers and
;;      every other Docker client wants: they do not speak to Podman's
;;      CLI, they speak to `/var/run/docker.sock' -- or to whatever
;;      DOCKER_HOST names.  `podman system service' provides exactly
;;      that API over a unix socket, one service per user, and the
;;      environment written into a job (see (byggsteg container) in the
;;      Byggsteg checkout) points DOCKER_HOST at it.
;;
;; The two sockets are therefore part of the machine's service list, not
;; of a container: they live under /run/user/<uid>/podman/, and the
;; maintenance job in (wolk-jjba maintenance) prunes the images and the
;; build cache of the same two users.
;;
;; Code:

(define-module (wolk-jjba containers)
  #:use-module (gnu)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services containers)
  #:use-module (gnu system accounts)
  #:use-module (gnu packages base)
  #:use-module (gnu packages containers)
  #:use-module (gnu packages file-systems)
  #:use-module (gnu packages freedesktop)
  #:use-module (guix gexp)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (wolk-jjba prelude)
  #:export (podman-users
            podman-group
            podman-cgroup-group
            byggsteg-runner
            byggsteg-directory
            podman-runtime-directory
            podman-socket-directory
            podman-socket-path
            podman-docker-host
            podman-environment
            podman-configuration
            podman-user-sessions-service
            podman-api-socket-service
            containers-log-files
            containers-service-type
            containers-capability))

;;; ====== The accounts ======
;;;
;;; One list, read by everything that has to know who owns podman state:
;;; this module (subids, session directories, API sockets), and
;;; (wolk-jjba maintenance) (the weekly prune).  Adding a third account
;;; that builds in containers is one edit here -- plus the account itself
;;; in config.scm, and a subuid/subgid range, which this module derives
;;; from the name.

(define-public podman-users
  '("joe" "byggsteg-runner"))

;; Both accounts are created with this as their primary group (see
;; config.scm), and it is what makes the Byggsteg checkout shared: the
;; daemon writes a clone as root:users, the runner writes a container's
;; output as byggsteg-runner:users, and either can read and write what
;; the other made.
(define-public podman-group "users")

;; The group whose ownership of /sys/fs/cgroup is what lets a rootless
;; container create its own cgroup.  Both accounts are members (see
;; config.scm), and the API service below passes it explicitly, because
;; a service that is given a #:group has its supplementary groups reset
;; to exactly the list it names.
(define-public podman-cgroup-group "cgroup")

;; The account Byggsteg's container builds run as.  It has a home
;; directory and a subuid range but no login, and it is in `wheel' so
;; that a job can run `sudo herd restart'.
(define-public byggsteg-runner "byggsteg-runner")

;; Where Byggsteg keeps its checkouts, its database and its artifacts.
;; The runner has to be able to write under it, and so does joe (the
;; same tree is the wolk-jjba checkout that `maak sr' is run from), which
;; is why the activation below makes it group-writable instead of
;; handing it to one of them.
(define-public byggsteg-directory "/etc/byggsteg")

;;; ====== Paths and environment ======
;;;
;;; These are procedures of the numeric uid rather than of a user name,
;;; because everything that runs *as* a user -- the API socket service,
;;; a job's command wrappers, the prune job -- has the uid at hand and
;;; looking the name up again would only be another way to get it wrong.

(define (podman-runtime-directory uid)
  "Return the XDG runtime directory owned by UID."
  (format #f "/run/user/~a" uid))

(define (podman-socket-directory uid)
  "Return the directory holding UID's Docker-compatible Podman socket."
  (format #f "/run/user/~a/podman" uid))

(define (podman-socket-path uid)
  "Return the Docker-compatible Podman socket of UID."
  (format #f "/run/user/~a/podman/podman.sock" uid))

(define (podman-docker-host uid)
  "Return the DOCKER_HOST value that reaches UID's Podman socket.

This is the address a Docker client -- testcontainers, docker compose,
`docker run', an SDK -- connects to.  Podman's own CLI ignores it
unless it is asked to go remote, so setting it cannot break the local
`podman' command."
  (string-append "unix://" (podman-socket-path uid)))

(define* (podman-environment uid #:key (home "/") (path #f))
  "Return the environment a Podman process running as UID needs.

A rootless Podman needs to know two things the environment of a
Shepherd daemon does not carry: which directory is its XDG runtime
directory (sockets, locks and the container's runroot live there), and
where its home is (the storage root, the pull cache and
`containers/auth.json' are relative to it).  DOCKER_HOST is added for
the Docker clients a build may start."
  (append (list (format #f "HOME=~a" home)
                (format #f "XDG_RUNTIME_DIR=~a"
                         (podman-runtime-directory uid))
                (format #f "DOCKER_HOST=~a" (podman-docker-host uid))
                "TMPDIR=/tmp")
          (if path
              (list (format #f "PATH=~a" path)) '())))

;;; ====== /etc/containers ======
;;;
;;; Guix's service writes three of the four files itself; the fourth
;;; (containers.conf) is added by the service type below.  The three
;;; Guix writes are replaced here because their defaults are aimed at a
;;; desktop, not at a build server:
;;;
;;;   - its registries.conf searches fedora and opensuse registries
;;;     before docker.io, which is not where this machine's images are;
;;;   - its storage.conf leaves the driver at `overlay' with no mount
;;;     program, which fails rootless on a kernel that does not allow
;;;     overlay in a user namespace;
;;;   - its policy.json is already `insecureAcceptAnything', which is
;;;     what a build server needs (signature checking would refuse every
;;;     image that was not signed with a key this machine knows), and it
;;;     is spelled out here so that the decision is visible rather than
;;;     inherited.

(define-public %podman-registries-conf
  "unqualified-search-registries = [\"docker.io\", \"quay.io\", \"ghcr.io\", \"registry.gitlab.com\"]
short-name-mode = \"enforcing\"
")

(define-public %podman-storage-conf
  "[storage]
driver = \"overlay\"
[storage.options.overlay]
mount_program = \"/run/current-system/profile/bin/fuse-overlayfs\"
mountopt = \"nodev\"
")

(define-public %podman-policy-json
  "{\"default\": [{\"type\": \"insecureAcceptAnything\"}]}
")

(define-public %podman-containers-conf
  "[containers]
default_rootless_network_cmd = \"pasta\"

[engine]
# Guix System has no systemd, so there is no user manager to ask for a
# cgroup: the cgroupfs manager creates the container's cgroup directly,
# as the user, which is what the cgroup delegates in
# (rootless-podman-service-type) are for.
cgroup_manager = \"cgroupfs\"
events_logger = \"file\"
")

;;; ====== The Podman service itself ======

(define* (podman-configuration #:key (users podman-users))
  "Return the rootless Podman configuration for USERS.

Guix's `rootless-podman-service-type' is the half of the job that has to
be done at account-creation time: it writes /etc/subuid and /etc/subgid,
creates the `cgroup' group, makes /sys/fs/cgroup group-writable, mounts
/ shared (which Buildah expects), and installs the Podman package.  The
configuration below is that service's value, with one subuid and one
subgid range per user and the three files replaced.

Instantiate it in config.scm as

  (service rootless-podman-service-type (podman-configuration))

and add (containers-capability) beside it: the two are separate halves
of the same setup, and a machine that has only the first has subids and
no API socket."
  (rootless-podman-configuration
   (group-name "cgroup")
   (subuids (map (lambda (user)
                   (subid-range (name user)))
                 users))
   (subgids (map (lambda (user)
                   (subid-range (name user)))
                 users))
   (containers-registries (plain-file "registries.conf"
                                      %podman-registries-conf))
   (containers-storage (plain-file "storage.conf"
                                   %podman-storage-conf))
   (containers-policy (plain-file "policy.json"
                                  %podman-policy-json))))

;;; ====== The sessions ======
;;;
;;; Podman's rootless mode needs an XDG_RUNTIME_DIR that exists and is
;;; owned by the user.  A login gets one from elogind through PAM; a
;;; Shepherd daemon is never logged in, so nothing creates it.  The
;;; activation below makes the directory at boot (activation runs as
;;; root, before any service), and the one-shot service asks elogind to
;;; keep it (linger) so that elogind's own cleanup does not remove it
;;; when it notices that the user has no session.

(define (podman-user-sessions-service)
  "Return the one-shot Shepherd service that prepares rootless sessions.

It creates /run/user/<uid> for every account in `podman-users' and asks
elogind to keep it.  Both steps are idempotent: a directory that elogind
already made is only re-owned, and enabling linger for a user that
already has it changes nothing."
  (shepherd-service
   (provision '(podman-user-sessions))
   (requirement '(user-processes elogind dbus-system networking))
   (one-shot? #t)
   (documentation
    "Create the XDG runtime directories rootless Podman needs, and keep
them.")
   (start #~(lambda args
              (for-each (lambda (user)
                          (let ((pw (getpwnam user)))
                            (when pw
                              (let* ((uid (passwd:uid pw))
                                     (gid (passwd:gid pw))
                                     (dir (string-append
                                           "/run/user/"
                                           (number->string uid))))
                                (mkdir-p dir)
                                (chown dir uid gid)
                                (chmod dir #o700))
                              ;; Best effort: a machine without
                              ;; elogind still gets the directory above,
                              ;; which is the part Podman actually
                              ;; needs.
                              (catch #t
                                (lambda ()
                                  (system* #$(file-append elogind
                                                          "/bin/loginctl")
                                           "enable-linger" user))
                                (lambda args #f)))))
                        '#$podman-users)
              #t))
   (stop #~(const #t))))

(define* (podman-api-socket-service #:key (user byggsteg-runner))
  "Return the Shepherd service that serves USER's Podman API socket.

`podman system service' is Podman's Docker-compatible REST API.  A
socket per user is what lets an unprivileged process -- a test suite
that uses testcontainers, a compose file, a script that speaks the
Docker API -- act as that user with no daemon of its own, because the
service *is* that user: it runs as USER and only ever touches USER's
containers.

`--time=0' means the service never times out, which is what a service
wants; the socket is removed when the service stops."
  (let* ((name (string->symbol (format #f "podman-api-~a" user)))
         (log-file (format #f "~a/podman-api-~a.log"
                           wolk-jjba-log-directory
                           user)))
    (shepherd-service
     (provision (list name))
     (requirement '(podman-user-sessions networking))
     (documentation
      (format #f "Docker-compatible Podman API socket for ~a." user))
     (start #~(lambda args
                (mkdir-p #$wolk-jjba-log-directory)
                (let* ((user #$user)
                       (pw (getpwnam user))
                       (uid (passwd:uid pw))
                       (gid (passwd:gid pw))
                       (home (passwd:dir pw))
                       (runtime (string-append "/run/user/"
                                               (number->string uid)))
                       (socket-dir (string-append runtime "/podman"))
                       (socket (string-append socket-dir "/podman.sock")))
                  ;; The socket's directory belongs to the user, not to
                  ;; root: the service drops privileges and creates the
                  ;; socket itself.
                  (mkdir-p socket-dir)
                  (chown socket-dir uid gid)
                  (chmod socket-dir #o700)
                  ((make-forkexec-constructor
                    (list #$(file-append podman "/bin/podman")
                          "system" "service" "--time=0"
                          (string-append "unix://" socket))
                    #:user user
                    #:group #$podman-group
                    ;; A service given a #:group has its supplementary
                    ;; groups reset, so the cgroup group has to be
                    ;; named again here or podman cannot create the
                    ;; container's own cgroup.
                    #:supplementary-groups
                    (list #$podman-group #$podman-cgroup-group)
                    #:environment-variables
                    (list (format #f "HOME=~a" home)
                          (format #f "XDG_RUNTIME_DIR=~a" runtime)
                          ;; `/run/privileged/bin' comes first, and it is
                          ;; load-bearing: that is where the setuid copies
                          ;; of `newuidmap' and `newgidmap' live.  The
                          ;; profile carries the same names as plain
                          ;; binaries, and Podman finds `newuidmap' through
                          ;; PATH -- so a profile-first PATH hands it a
                          ;; helper that cannot write `/proc/<pid>/uid_map',
                          ;; and every rootless command fails with
                          ;;   newuidmap: write to uid_map failed:
                          ;;   Operation not permitted
                          ;; which is what this service did until the order
                          ;; was fixed.  The daemons' own PATH already
                          ;; starts there; this one has to as well.
                          "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin")
                    #:log-file #$log-file)
                   args))))
     (stop #~(make-kill-destructor))
     (respawn? #t))))

;;; ====== The service type ======

(define (containers-shepherd-services config)
  "Return the Shepherd services of the containers capability."
  (cons (podman-user-sessions-service)
        (map (lambda (user)
               (podman-api-socket-service #:user user))
             podman-users)))

;; Everything that has to exist before a container can be built.  Two
;; of these are not obvious:
;;
;;   - the runtime directories, because activation runs before
;;     `podman-user-sessions' and before any login;
;;   - the group-writable /etc/byggsteg tree.  Byggsteg's daemon writes
;;     a clone and the container writes the build output, and the two
;;     do it as different accounts; making the group own the write is
;;     what lets the same checkout be built by one and read by the
;;     other (and by joe, who runs `maak sr' there).
(define (containers-activation config)
  #~(begin
      (use-modules (guix build utils))
      (for-each (lambda (user)
                  (let ((pw (getpwnam user)))
                    (when pw
                      (let ((dir (string-append "/run/user/"
                                                (number->string
                                                 (passwd:uid pw)))))
                        (mkdir-p dir)
                        (chown dir (passwd:uid pw) (passwd:gid pw))
                        (chmod dir #o700)))))
                '#$podman-users)
      (when (file-exists? #$byggsteg-directory)
        ;; `g+rwX' gives the group read and write everywhere, and the
        ;; execute bit only where there already is one (X), so ordinary
        ;; files stay ordinary files.
        (system* #$(file-append coreutils "/bin/chmod") "-R" "g+rwX"
                 #$byggsteg-directory))))

(define (containers-etc config)
  "Return the files this capability adds under /etc."
  (list `("containers/containers.conf"
          ,(plain-file "containers.conf" %podman-containers-conf))))

(define (containers-profile-packages config)
  "Return the packages a machine that builds in containers needs.

Podman itself is installed by `rootless-podman-service-type'.  What is
added here is the rest of a working rootless setup:

  fuse-overlayfs     the overlay driver without kernel support for
                     overlay in a user namespace;
  slirp4netns        the user-mode network for kernels or images where
                     `pasta' is not usable;
  podman:docker      a `docker' command that is Podman, for the tools
                     that invoke the Docker CLI by name."
  (list fuse-overlayfs
        slirp4netns
        (list podman "docker")))

(define (containers-log-files)
  "Return the log files the Podman API services write."
  (map (lambda (user)
         (format #f "~a/podman-api-~a.log" wolk-jjba-log-directory user))
       podman-users))

(define containers-service-type
  (service-type
   (name 'wolk-jjba-containers)
   (extensions
    (list (service-extension shepherd-root-service-type
                              containers-shepherd-services)
          (service-extension activation-service-type
                             containers-activation)
          (service-extension etc-service-type
                             containers-etc)
          (service-extension profile-service-type
                             containers-profile-packages)
          ;; The same two daemons' logs are rotated with the rest.
          (service-extension log-rotation-service-type
                             (const (containers-log-files)))))
   (default-value '())
   (description
    "Rootless Podman for the accounts that build in containers, with a
Docker-compatible API socket per account.")))

(define (containers-capability)
  "Return the service that makes this machine able to build in containers."
  (service containers-service-type))
