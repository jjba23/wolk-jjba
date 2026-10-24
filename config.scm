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

(use-modules (gnu)
             (guix)
             (guix packages)
             (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 time)
             (ice-9 format)
             (ice-9 string-fun)
             (ice-9 iconv)
             (ice-9 rdelim)
             (ice-9 threads))

(use-modules (guix git-download)
             (gnu system locale)
             (gnu packages ssh)
             (gnu packages audio)
             (gnu packages admin)
             (gnu packages xiph)
             (gnu packages shells)
             (gnu packages monitoring)
             (gnu packages databases)
             (gnu packages file-systems)
             (gnu packages package-management)
             (gnu services shepherd)
             ((guix licenses)
              #:prefix license:)
             (guix build-system gnu)
             (wolk-jjba nginx)
             (gnu system accounts)
             (wolk-jjba certbot)
             (wolk-jjba containers)
             (wolk-jjba packages)
             (wolk-jjba minecraft)
             (wolk-jjba prelude)
             (wolk-jjba iptables)
             (wolk-jjba secrets)
             (wolk-jjba sysctl)
             (wolk-jjba jobs)
             (wolk-jjba maintenance)
             (wolk-jjba radio)
             (wolk-jjba monitoring)
             (wolk-jjba logging))

(use-service-modules networking
                     desktop
                     ssh
                     avahi
                     audio
                     admin
                     databases
                     monitoring
                     mail
                     containers
                     nix
                     sysctl
                     web
                     dbus)

(define wolk-jjba-locale
  "en_US.utf8")

;; Set to #t for the first reconfigure of a new machine: only the ACME
;; and metrics vhosts are emitted, until the Let's Encrypt certificates
;; exist.
(define wolk-jjba-minimal-nginx? #f)

;; A locale definition compiles glibc's rules for one language: date and
;; number formatting, collation, the LC_* a login shell exports, and -- the
;; part that decides whether a translated page is readable -- the codeset
;; gettext converts catalog entries into.  It does *not* translate
;; anything: a language appears on a site only when that application
;; ships the catalog under its own sys/i18n/locale, so this list and those
;; directories should be kept in step.
;;
;; %default-locale-definitions already compiles the six UN languages plus
;; Portuguese (ar_DZ, en_GB, en_US, es_AR, es_ES, fr_FR, pt_BR, pt_PT,
;; ru_RU, zh_CN).  Repeating one of those here would only compile it
;; twice, so the list below is the additions.
(define wolk-jjba-locale-names
  '("ja_JP"                             ; 日本語, the stack's first translation
    "nl_NL" "de_DE" "it_IT"             ; languages the applications ship
    "el_GR"                             ; Ελληνικά
    "zh_TW"                             ; 繁體中文 -- zh_CN is a default
    "ar_SA"                             ; العربية -- ar_DZ is a default
    "cs_CZ" "da_DK" "fi_FI" "nb_NO" "pl_PL" "sv_SE" "tr_TR" "uk_UA"
    "hi_IN"))

(define wolk-jjba-locale-definitions
  ;; The lambda parameter must not be called `name'.  `locale-definition'
  ;; is a `define-record-type*' constructor, and that macro wraps each
  ;; field value in a `let*' that binds the field names themselves, so a
  ;; value expression that is the identifier `name' reads the record's
  ;; own NAME field instead of the surrounding variable.  Written that
  ;; way, every entry below came out with source "ja_JP.utf8" instead of
  ;; "ja_JP", and building the locale directory failed with "cannot open
  ;; locale definition file" -- the system's locales are built with
  ;; `localedef -i <source>', and there is no ja_JP.utf8 source file.
  (append (map (lambda (locale-name)
                 (locale-definition
                  (name (string-append locale-name ".utf8"))
                  (source locale-name)))
               wolk-jjba-locale-names)
          %default-locale-definitions))

(define wolk-jjba-keyboard-layout
  (keyboard-layout "us"))

(define wolk-jjba-filesystems
  (list (file-system
          (mount-point "/")
          (device (uuid "469a9193-ec26-45d9-bf26-50cc8d6355d7"
                        'btrfs))
          (type "btrfs"))
        (file-system
          (mount-point "/boot/efi")
          (device (uuid "E416-7905"
                        'fat32))
          (type "vfat"))
        (file-system
          (mount-point "/mnt/wolkenschlosslagerung")
          (device "//u600604.your-storagebox.de/backup")
          (type "cifs")
          ;; The music library is read-only for this host (MPD reads it;
          ;; nothing here writes it), so:
          ;;
          ;;   noatime  reading a file must not write to the box;
          ;;   soft     a read that cannot be served fails in seconds
          ;;            instead of blocking the reader forever.  With the
          ;;            default (hard) a Storage Box that goes away puts
          ;;            MPD into uninterruptible sleep: `herd restart mpd'
          ;;            cannot even kill it, and the radio stays silent
          ;;            until the box comes back.  A failed read costs a
          ;;            skipped track; a hung process costs the station.
          ;;
          ;; Nothing else belongs in this list.  The kernel's CIFS client
          ;; is strict about its mount options -- it prints "cifs: Unknown
          ;; parameter 'NAME'" to the kernel log and mount(2) then fails
          ;; with EINVAL, which shepherd reports as
          ;;     could not mount partition '//u600604.../backup':
          ;;     Invalid argument
          ;; and the file-system service never starts.  "timeo" and
          ;; "retrans" were accepted for years and are gone in Linux 7.x,
          ;; and they were the two options that took the whole Storage Box
          ;; offline on the first boot after the 7.1.5 upgrade: the
          ;; backup volume disappeared, MPD lost its library and every
          ;; reboot logged the same failure.  "soft" is what bounds a
          ;; dead read now (the kernel keeps "echo_interval" for the
          ;; liveness probe), so the timeout pair was redundant anyway.
          (options
           "credentials=/etc/samba/credentials,uid=1000,gid=1000,iocharset=utf8,vers=3.0,noatime,soft")
          (mount? #t)
          (create-mount-point? #t)
          (shepherd-requirements '(networking)))))

(define wolk-jjba-swap-devices
  (list (swap-space
          (target (uuid "dfdb88fb-1a57-4aaf-bc55-6da4399811ba")))))

(define wolk-jjba-bootloader
  (bootloader-configuration
    (bootloader grub-efi-bootloader)
    (targets (list "/boot/efi"))
    (keyboard-layout wolk-jjba-keyboard-layout)))

(define wolk-jjba-joe-user-account
  (user-account
    (name "joe")
    (group "users")
    (home-directory "/home/joe")
    (comment "Josep Bigorra's account")
    (supplementary-groups '("wheel" "netdev"
                            "audio"
                            "video"
                            "input"
                            "cgroup"
                            "mpd"))))

(define wolk-jjba-minecraft-daemon-user-account
  (user-account
    (name "minecraft-daemon")
    (group "users")
    (supplementary-groups '("netdev" "audio" "video" "input"))))

(define wolk-jjba-byggsteg-runner-user-account
  (user-account
    (name "byggsteg-runner")
    (group "users")
    (home-directory "/home/byggsteg-runner")
    (comment "Byggsteg runner's account")
    (supplementary-groups '("wheel" "netdev" "audio" "video" "input" "cgroup"))))

(define wolk-jjba-backer-upper-user-account
  (user-account
    (name "backer-upper")
    (group "users")
    (supplementary-groups '("netdev" "audio" "video" "input" "mpd"))))

(define wolk-jjba-ssh-service
  (service openssh-service-type
           (openssh-configuration (openssh openssh-sans-x)
                                  (password-authentication? #f)
                                  (port-number 2323)
                                  (max-connections 12))))

;; The MPD and Icecast passwords live in root-only files, and this file
;; reads them while it is evaluated.  Where those files are, how a missing
;; one is reported, and the WOLK_JJBA_SECRETS override that lets a build --
;; or the test suite, see test/veritas/unit/operating-system-spec.scm --
;; run as an ordinary user against fixture files is all in (wolk-jjba
;; secrets), together with the rest of the secrets contract: the registry
;; credentials that are derived from /etc/secrets for Podman, and the
;; `secrets-apply' timer that writes them.  On the machine itself the
;; variable is unset and the files are read from /etc/secrets, as before.

(define mpd-admin-password
  (read-secret "mpd-admin"))

(define mpd-read-password
  (read-secret "mpd-read"))

;; Icecast's source password is what MPD authenticates with when it
;; pushes the stream, and the admin password guards the status page's
;; admin interface.  They used to be the literals "hackme_source" and
;; "hackme_admin" in this file, which meant anyone who had read the
;; repository could take over the mounts.
(define icecast-source-password
  (read-secret "icecast-source"))

(define icecast-admin-password
  (read-secret "icecast-admin"))

;; MPD and Icecast are built by (wolk-jjba radio), which also owns the
;; health check, the nightly library scan and the three stream mounts.
(define wolk-jjba-mpd-service
  (service mpd-service-type
           (radio-mpd-configuration
            #:source-password icecast-source-password
            #:admin-password mpd-admin-password
            #:read-password mpd-read-password)))

(define wolk-jjba-icecast-service
  (icecast-shepherd-service
   #:source-password icecast-source-password
   #:admin-password icecast-admin-password))

(define wolk-jjba-postgres
  (service postgresql-service-type
           (postgresql-configuration (postgresql postgresql-16)
                                     (config-file (postgresql-config-file (hba-file
                                                                           (plain-file
                                                                            "pg_hba.conf"
                                                                            "
local   all    all    peer
host    all    all    127.0.0.1/32   trust
host    all    all    ::1/128        trust
")))))))

(define wolk-jjba-os
  (operating-system
    (host-name "wolk-jjba")
    (timezone "Europe/Amsterdam")
    (locale wolk-jjba-locale)
    (locale-definitions wolk-jjba-locale-definitions)
    (keyboard-layout wolk-jjba-keyboard-layout)
    (sudoers-file (plain-file "sudoers"
                              (string-join '("root ALL=(ALL) NOPASSWD:ALL"
                                             "%wheel ALL=(ALL) NOPASSWD:ALL"
                                             "joe ALL=(ALL) NOPASSWD:ALL")
                                           "\n")))
    (initrd-modules (append (list "virtio_scsi") %base-initrd-modules))
    (file-systems (append wolk-jjba-filesystems %base-file-systems))
    (bootloader wolk-jjba-bootloader)
    (swap-devices wolk-jjba-swap-devices)
    (groups %base-groups)
    (users (cons* wolk-jjba-minecraft-daemon-user-account
                  wolk-jjba-backer-upper-user-account
                  wolk-jjba-joe-user-account
                  wolk-jjba-byggsteg-runner-user-account
                  %base-user-accounts))

    (packages (append wolk-jjba-system-packages %base-packages))

    (services
     (system-log-capability
      (cons* (service dbus-root-service-type)
            (service avahi-service-type)
            (service udisks-service-type)
            (service upower-service-type)
            (service accountsservice-service-type)
            (service openntpd-service-type
                     (openntpd-configuration (listen-on '("127.0.0.1" "::1"))
                                             (sensor '("udcf0 correction 70000"))
                                             (constraint-from '("www.gnu.org"))
                                             (constraints-from '("https://www.google.com/"))))
            wolk-jjba-ssh-service
            wolk-jjba-icecast-service
            wolk-jjba-mpd-service
            ;; The radio health check (every 5 minutes), the nightly
            ;; library scan, the icecast log rotation and the
            ;; /var/lib/mpd/playlists activation.
            (radio-capability)
            wolk-jjba-postgres
            wolk-jjba-iptables-service
            (service mail-aliases-service-type
                     '(("postmaster" "joe")
                       ("joe" "jjbigorra@gmail.com")))
            ;; Rootless Podman is kept for Byggsteg's build runners: a
            ;; job that builds in a container runs it as
            ;; byggsteg-runner, so the image, the build cache and the
            ;; containers all belong to a user that is not root.  See
            ;; (wolk-jjba containers) for the subuid ranges, the
            ;; storage configuration, the Docker-compatible API
            ;; sockets that testcontainers connects to, and the
            ;; `secrets-apply' timer that logs both accounts in to a
            ;; private registry from /etc/secrets.
            (service rootless-podman-service-type (podman-configuration))
            (containers-capability)
            (service nix-service-type
                     (nix-configuration (extra-config (list
                                                       "experimental-features = nix-command flakes"))))
            (service elogind-service-type)
            (service network-manager-service-type)
            (service wpa-supplicant-service-type)
            ;; node exporter has no authentication and everything that
            ;; scrapes it (Prometheus) runs on this host, so it listens
            ;; on loopback only.  Its textfile collector reads
            ;; /var/lib/prometheus/node-exporter, which is where
            ;; (wolk-jjba maintenance) publishes the backup and store
            ;; metrics.
            (service prometheus-node-exporter-service-type
                     (prometheus-node-exporter-configuration
                      (web-listen-address "127.0.0.1:9100")))
            (service wolk-jjba-monitoring-service-type)
            (service modem-manager-service-type)
            (nginx-capability #:minimal-conf wolk-jjba-minimal-nginx?)
            (certbot-capability)
            (service wolk-jjba-minecraft-server-service-type)
            (make-guile-server-shepherd-daemon #:service-name 'byggsteg-daemon
             #:provision '(byggsteg-daemon)
             #:cmd '("maak" "production-server")
             #:directory (byggsteg-managed-project-dir 'byggsteg)
             ;; The daemon stays root because `maak' builds in the Guix
             ;; store -- /gnu/store is writable by root and by the build
             ;; users only, and every application here runs `guix shell'
             ;; as part of its own task.  What it must *not* be is the
             ;; user that owns the containers: a job that names an image
             ;; is run by Byggsteg as `byggsteg-runner' (see
             ;; BYGGSTEG_CONTAINER_USER below), which is what makes
             ;; those containers rootless.
             ;;
             ;; `users' is the group of both accounts, and umask 002 is
             ;; what makes a clone the daemon writes editable by the
             ;; container that builds it (and by joe, who runs
             ;; `maak sr' from the same checkout).
             #:group "users"
             #:file-creation-mask #o002
             #:extra-env (list "BYGGSTEG_CONTAINER_RUNTIME=podman"
                               (string-append "BYGGSTEG_CONTAINER_USER="
                                              byggsteg-runner))
             #:documentation "Run Byggsteg as a Herd/Shepherd daemon")
            (make-guile-server-shepherd-daemon #:service-name 'torikomi-daemon
             #:provision '(torikomi-daemon)
             #:cmd '("maak" "production-server")
             #:directory (byggsteg-managed-project-dir 'torikomi)
             #:documentation "Run Byggsteg as a Herd/Shepherd daemon")
            (make-guile-server-shepherd-daemon #:service-name 'lucidplan-daemon
             #:provision '(lucidplan-daemon)
             #:cmd '("maak" "production-server")
             #:directory (byggsteg-managed-project-dir 'lucidplan)
             #:documentation "Run LucidPlan as a Herd/Shepherd daemon")
            (make-guile-server-shepherd-daemon #:service-name 'symbanta-api-daemon
             #:provision '(symbanta-api-daemon)
             #:cmd '("maak" "production-server")
             #:directory (byggsteg-managed-project-dir 'symbanta)
             #:documentation "Run Symbanta API as a Herd/Shepherd daemon")
            (make-guile-server-shepherd-daemon #:service-name 'wikimusic-daemon
             #:provision '(wikimusic-daemon)
             #:cmd '("maak" "production-server")
             #:directory (byggsteg-managed-project-dir 'wikimusic)
             #:documentation "Run WikiMusic as a Herd/Shepherd daemon")
            (make-guile-server-shepherd-daemon #:service-name 'pingwing-daemon
             #:provision '(pingwing-daemon)
             #:cmd '("maak" "production-server")
             #:directory (byggsteg-managed-project-dir 'pingwing)
             #:documentation "Run PingWing as a Herd/Shepherd daemon")
            (shepherd-jobs-capability)
            ;; Disk hygiene: weekly garbage collection of the Guix and
            ;; Nix stores, container and cache pruning, /tmp cleanup,
            ;; backup verification, and the metrics that make all of it
            ;; visible (see (wolk-jjba maintenance)).
            (maintenance-capability)
            (auto-upgrade-capability)
            ;; Rotate service logs earlier than the Shepherd default and
            ;; keep a week of them: the same lines are in Loki, so the
            ;; local copies only need to bridge the time it takes to
            ;; notice that the stack itself is unhealthy.  This bounds
            ;; the disk cost of /var/log and /var/log/wolk-jjba.
            ;;
            ;; The kernel settings are extended in place rather than added
            ;; as a second sysctl service: see extend-sysctl-configuration
            ;; in (wolk-jjba sysctl) for why the second service does not
            ;; fold.  They are the other half of the firewall -- SYN
            ;; cookies, reverse-path filtering, ICMP rate limits -- while
            ;; the rule list lives in (wolk-jjba iptables).
            (modify-services %base-services
              (sysctl-service-type config =>
                (extend-sysctl-configuration config))
              (log-rotation-service-type config =>
                (log-rotation-configuration
                 (inherit config)
                 (size-threshold (* 20 1024 1024))
                 (expiry (* 7 24 3600))))))))))

wolk-jjba-os
