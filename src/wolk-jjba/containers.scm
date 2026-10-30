;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

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
;; A `podman system service' needs one thing more, and it is the piece
;; that broke here: a cgroup of its own.  Podman 6's `system service'
;; calls cgroups.MaybeMoveToSubCgroup at startup (see
;; (byggsteg container)'s machine counterpart, containers/common), and
;; when its process is in the *root* cgroup that function creates
;; /sys/fs/cgroup/init and moves *every process of the root cgroup* into
;; it.  It is meant for `podman' running as PID 1 inside a container, but
;; on a Guix System every Shepherd service starts in the root cgroup, so
;; the first socket to start would move the Shepherd and every daemon
;; into a directory owned by the account that started it -- and that
;; directory has mode 0600, so the next Podman to read its own
;; cgroup.controllers (`podman info', which every Docker client asks for
;; first) fails with "permission denied".  That is the error testcontainers
;; printed as "Could not find a valid Docker environment".  The fix is to
;; put the API service's podman into podman-service-cgroup below before it
;; starts: Podman's test is "is my cgroup /?", and it answers no.
;;
;; A sixth thing is not part of Podman's setup but of its *use*: a private
;; image needs a credential, and Podman reads it from the account's own
;; home (see "The registry login" below).  The token is one more secret in
;; /etc/secrets, and the file that holds it is derived from there by a
;; timer, so no account on this machine is ever logged in by hand.
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
  #:use-module (gnu packages bash)
  #:use-module (gnu packages containers)
  #:use-module (gnu packages file-systems)
  #:use-module (gnu packages freedesktop)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (wolk-jjba jobs)
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
            podman-service-cgroup
            podman-environment
            podman-configuration
            podman-user-sessions-service
            podman-api-socket-service
            secrets-apply-program
            secrets-apply-service
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

(define (podman-service-cgroup user)
  "Return the cgroup the API service of USER runs its podman in.

`podman system service' starts by asking whether its own cgroup is the
root one; if it is, it moves every process of that cgroup into a new
sub-cgroup named `init' (cgroups.MaybeMoveToSubCgroup in
containers/common).  That is the right thing for a podman that is PID 1
inside a container and the wrong thing here: the first socket to start
would move the Shepherd and every daemon into /sys/fs/cgroup/init, a
directory owned by USER with no execute bit, and every podman that later
reads its own cgroup.controllers would be told permission denied.

Starting the service in a cgroup of its own makes Podman's question
answer no.  The directory is created and handed to USER by the service
start below, because the kernel creates the files in it (cgroup.procs
above all) owned by whoever makes the directory."
  (format #f "/sys/fs/cgroup/podman-api-~a" user))

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
already has it changes nothing.

It also repairs /sys/fs/cgroup/init when an older boot left one behind
(see `podman-service-cgroup'): the directory is handed back to root and
made traversable, so the processes in it can read their own cgroup and
the account that started that podman no longer holds a writable
cgroup.kill for the whole machine."
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
              ;; A machine that booted before the API service got a
              ;; cgroup of its own has PID 1 and every daemon in
              ;; /sys/fs/cgroup/init, owned by whichever account started
              ;; that service first (see `podman-service-cgroup').  A
              ;; reboot starts without it; until then, hand it back to
              ;; root and make it traversable.  Without the chown its
              ;; owner keeps a writable cgroup.kill for the whole
              ;; system, and without the chmod nothing in it can read
              ;; its own cgroup.controllers.
              (let ((stale "/sys/fs/cgroup/init"))
                (when (file-exists? stale)
                  (catch #t
                    (lambda ()
                      (system* #$(file-append coreutils "/bin/chown")
                               "-R"
                               (string-append "root:" #$podman-cgroup-group)
                               stale)
                      (chmod stale #o755))
                    (lambda args #f))))
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
wants; the socket is removed when the service stops.

The podman process is started in `podman-service-cgroup', not in the
root cgroup: a `podman system service' that finds itself in the root
cgroup moves every process of that cgroup into /sys/fs/cgroup/init
before it serves a request, which on this machine would move PID 1 and
every daemon into a directory the account owns.  See
`podman-service-cgroup' for the whole failure."
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
                       (socket (string-append socket-dir "/podman.sock"))
                       (cgroup #$(podman-service-cgroup user)))
                  ;; The socket's directory belongs to the user, not to
                  ;; root: the service drops privileges and creates the
                  ;; socket itself.
                  (mkdir-p socket-dir)
                  (chown socket-dir uid gid)
                  (chmod socket-dir #o700)
                  ;; The cgroup belongs to the user too.  `mkdir-p'
                  ;; creates it as root, and the kernel creates the
                  ;; files in it (cgroup.procs, which the wrapper below
                  ;; writes) owned by root as well, so both the
                  ;; directory and the files a process writes have to
                  ;; be handed over.  0755 lets the user create the
                  ;; container's own cgroup below it; 0644 gives the
                  ;; owner the write bit the cgroup files need.
                  (mkdir-p cgroup)
                  (chown cgroup uid gid)
                  (chmod cgroup #o755)
                  (for-each (lambda (file)
                              (let ((path (string-append cgroup "/" file)))
                                (when (file-exists? path)
                                  (chown path uid gid)
                                  (chmod path #o644))))
                            '("cgroup.procs"
                              "cgroup.subtree_control"
                              "cgroup.threads"))
                  ((make-forkexec-constructor
                    ;; The wrapper writes its own pid -- the pid
                    ;; `exec' keeps -- into the cgroup before
                    ;; becoming podman.  Starting podman in the root
                    ;; cgroup instead is what created the /init
                    ;; directory described above.
                    ;;
                    ;; The script is a literal and the runtime paths
                    ;; arrive as its arguments, rather than all of it
                    ;; being a `format' call: a formatted command is
                    ;; opaque to `gexp->approximate-sexp', so the spec
                    ;; that reads this service back could no longer
                    ;; see the `system service --time=0 unix://...' it
                    ;; starts.  `${@:2}' is podman and its flags, as
                    ;; separate words, because argument lists and not
                    ;; quoted strings are what the spec checks.
                    (list #$(file-append bash-minimal "/bin/bash")
                          "-c"
                          "echo $$ > \"$1/cgroup.procs\" && exec \"${@:2}\""
                          "podman-api-wrapper"
                          cgroup
                          #$(file-append podman "/bin/podman")
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

;;; ====== The registry login ======
;;;
;;; A private image is behind a credential, and Podman has no flag to give
;;; it one: it reads `$HOME/.config/containers/auth.json', and that file is
;;; per-account -- the API socket service above runs as byggsteg-runner, so
;;; a build pulls as byggsteg-runner, so it needs its own copy.  Writing
;;; that by hand means `podman login' once per account, on the machine, with
;;; the token typed into a shell that keeps a history of it.
;;;
;;; So the token is a secret like the others -- /etc/secrets/dockerhub-token,
;;; root-only, pushed from the machine that holds the encrypted copy with
;;; `maak secrets' -- and the machine derives the auth files from it:
;;; (wolk-jjba secrets) knows what to write and who gets a copy, this timer
;;; runs it every quarter of an hour, and `herd trigger secrets-apply' runs
;;; it now.  The derived file is never the source of truth: delete a home,
;;; reinstall the account, and the next run puts the login back.
;;;
;;; A quarter of an hour is soon enough, because the file is not needed
;;; until a pull happens and nothing pulls at boot.  It is also cheap: the
;;; program reads at most a few dozen bytes and writes nothing at all when
;;; the file already says what it should (see `install-derived-file').

;; `source-module-closure' defaults to Guix's own modules -- its SELECT?
;; predicate is `guix-module-name?' -- so the repository's namespace has to
;; be named explicitly or the closure comes back empty and the program
;; fails at run time with "no code for module (wolk-jjba secrets)".  The
;; same three lines are in (wolk-jjba maintenance) for the gfs job; a
;; module imported by a program-file has to bring only Guile's own library
;; with it, which is why (wolk-jjba secrets) is plain Guile.
(define (wolk-jjba-module? name)
  "Return #t for a module name that this repository provides."
  (and (pair? name) (eq? (car name) 'wolk-jjba)))

(define (secrets-apply-arguments)
  "Return the command line that logs every container account in.

One --user per account in `podman-users', so a third account that builds
in containers gets a login by being added to that list and nowhere else."
  (append (list "secrets-apply" "--apply")
          (append-map (lambda (user)
                        (list "--user" user))
                      podman-users)))

(define secrets-apply-program
  (program-file "secrets-apply"
    (with-imported-modules (source-module-closure '((wolk-jjba secrets))
                                                 #:select? wolk-jjba-module?)
      #~(begin
          (use-modules (wolk-jjba secrets))
          ;; The program *is* the server job, so it applies.  The dry run is
          ;; what a human gets from `maak secrets-apply' and from
          ;; scripts/secrets-apply.scm, where a wrong --user costs nothing.
          (exit (main #:argv (list #$@(secrets-apply-arguments))))))))

(define (secrets-apply-service)
  "Return the timer that writes the files derived from /etc/secrets.

It runs as root because it writes into two accounts' homes, and it is
respawned so a reboot or a shepherd restart brings it back.  The log is
/var/log/wolk-jjba/secrets-apply.log, where a `nothing to derive' line
every quarter of an hour is the expected, healthy output of a machine
that pulls no private image."
  (make-timer-service
   #:name 'secrets-apply
   #:schedule "*/15 * * * *"
   #:program secrets-apply-program
   #:documentation
   "Write the files derived from /etc/secrets, such as the registry login of every account that builds containers."))

;;; ====== The service type ======

(define (containers-shepherd-services config)
  "Return the Shepherd services of the containers capability."
  (cons* (podman-user-sessions-service)
         (secrets-apply-service)
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
  "Return the log files the container services write.

The API sockets and the secrets timer: both are quiet when they work,
which is what makes their logs worth keeping and rotating."
  (cons (format #f "~a/secrets-apply.log" wolk-jjba-log-directory)
        (map (lambda (user)
               (format #f "~a/podman-api-~a.log" wolk-jjba-log-directory user))
             podman-users)))

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
