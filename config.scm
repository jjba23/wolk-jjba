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
             (wolk-jjba packages)
             (wolk-jjba minecraft)
             (wolk-jjba prelude)
             (wolk-jjba iptables)
             (wolk-jjba jobs)
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
          (options
           "credentials=/etc/samba/credentials,uid=1000,gid=1000,iocharset=utf8,vers=3.0")
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

(define wolk-jjba-icecast-user-account
  (user-account
    (name "icecast")
    (group "icecast")
    (system? #t)
    (comment "Icecast Service User")
    (home-directory "/var/run/icecast")
    (shell (file-append shadow "/sbin/nologin"))))

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

;; The two MPD passwords live in root-only files, and this file reads them
;; while it is evaluated.  WOLK_JJBA_SECRETS points the lookup at another
;; directory, which is what lets a build -- or the test suite, see
;; test/veritas/unit/operating-system-spec.scm -- run as an ordinary user
;; against fixture files.  On the machine itself the variable is unset and
;; the files are read from /etc/secrets, as before.
(define wolk-jjba-secrets-directory
  (or (getenv "WOLK_JJBA_SECRETS") "/etc/secrets"))

(define (read-secret name)
  "Return the first line of the file NAME in the secrets directory."
  (call-with-input-file (format #f "~a/~a" wolk-jjba-secrets-directory name)
    read-line))

(define mpd-admin-password
  (read-secret "mpd-admin"))

(define mpd-read-password
  (read-secret "mpd-read"))

(define wolk-jjba-mpd-service
  (service mpd-service-type
           (mpd-configuration (outputs (list (mpd-output (name
                                                          "Wolk JJBA Radio")
                                                         (type "shout")
                                                         (extra-options `((host . "127.0.0.1")
                                                                          (mount . "/radio.opus")
                                                                          (encoder . "opus")
                                                                          (password . "hackme_source")
                                                                          (bitrate . "128000")
                                                                          (format . "48000:16:2")
                                                                          (port . "6690"))))))
                              (decoders (list (mpd-plugin (plugin "mikmod")
                                                          (enabled? #t))
                                              (mpd-plugin (plugin "openmpt")
                                                          (enabled? #t)
                                                          (extra-options `((repeat-count . -1)
                                                                           (interpolation-filter . 1))))))
                              (resampler (mpd-plugin (plugin "libsamplerate")
                                                     (extra-options `((type . 0)))))
                              (music-directory
                               "/mnt/wolkenschlosslagerung/music")
                              (auto-update? #t)
                              (extra-options `((password unquote
                                                         (format #f
                                                          "~a@read,add,control,admin"
                                                          mpd-admin-password))
                                               (password unquote
                                                         (format #f
                                                          "~a@read,add,control"
                                                          mpd-read-password)))))))

(define icecast-config-file
  (plain-file "icecast.xml"
              "<?xml version=\"1.0\"?>
<icecast>
    <location>Amsterdam</location>
    <admin>jjbigorra@gmail.com</admin>

    <authentication>
        <source-password>hackme_source</source-password>
        <admin-user>admin</admin-user>
        <admin-password>hackme_admin</admin-password>
    </authentication>

    <limits>
        <clients>100</clients>
        <sources>2</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <burst-size>65535</burst-size>
    </limits>

    <hostname>wolk-jjba</hostname>

    <listen-socket>
        <port>6690</port>
        <bind-address>0.0.0.0</bind-address>
    </listen-socket>

    <paths>
        <logdir>/var/log/icecast</logdir>
        <webroot>/share/icecast/web</webroot>
        <adminroot>/share/icecast/admin</adminroot>
        <alias source=\"/\" destination=\"/status.xsl\"/>
    </paths>

    <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>3</loglevel>
    </logging>

    <security>
        <chroot>0</chroot>
    </security>
</icecast>"))

(define wolk-jjba-icecast-service
  (simple-service 'icecast-service shepherd-root-service-type
                  (list (shepherd-service (documentation
                                           "Run the Icecast streaming media server.")
                                          (provision '(icecast))
                                          (requirement '(networking user-homes))
                                          (start #~(lambda args
                                                     (mkdir-p
                                                      "/var/log/icecast")
                                                     (mkdir-p
                                                      "/var/log/wolk-jjba")
                                                     (let ((pw (getpwnam
                                                                "icecast")))
                                                       (chown
                                                        "/var/log/icecast"
                                                        (passwd:uid pw)
                                                        (passwd:gid pw)))
                                                     ((make-forkexec-constructor
                                                       (list #$(file-append
                                                                icecast
                                                                "/bin/icecast")
                                                             "-c"
                                                             #$icecast-config-file)
                                                       #:log-file
                                                       "/var/log/wolk-jjba/icecast.log"
                                                       #:user "icecast"
                                                       #:group "icecast")
                                                      args)))
                                          (stop #~(make-kill-destructor))))))

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
    (groups (cons* (user-group
                     (name "icecast")
                     (system? #t)) %base-groups))
    (users (cons* wolk-jjba-minecraft-daemon-user-account
                  wolk-jjba-backer-upper-user-account
                  wolk-jjba-joe-user-account
                  wolk-jjba-icecast-user-account
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
            wolk-jjba-postgres
            wolk-jjba-iptables-service
            (service mail-aliases-service-type
                     '(("postmaster" "joe")
                       ("joe" "jjbigorra@gmail.com")))
            ;; Podman is kept for Byggsteg's build runners.  The
            ;; observability stack is container-free; see
            ;; (wolk-jjba monitoring).
            (service rootless-podman-service-type
                     (rootless-podman-configuration (subgids (list (subid-range
                                                                    (name
                                                                     "joe"))
                                                                   (subid-range
                                                                    (name
                                                                     "byggsteg-runner"))))
                                                    (subuids (list (subid-range
                                                                    (name
                                                                     "joe"))
                                                                   (subid-range
                                                                    (name
                                                                     "byggsteg-runner"))))))
            (service nix-service-type
                     (nix-configuration (extra-config (list
                                                       "experimental-features = nix-command flakes"))))
            (service elogind-service-type)
            (service network-manager-service-type)
            (service wpa-supplicant-service-type)
            (service prometheus-node-exporter-service-type)
            (service wolk-jjba-monitoring-service-type)
            (service modem-manager-service-type)
            (nginx-capability #:minimal-conf wolk-jjba-minimal-nginx?)
            (certbot-capability)
            (service wolk-jjba-minecraft-server-service-type)
            (make-guile-server-shepherd-daemon #:service-name 'byggsteg-daemon
             #:provision '(byggsteg-daemon)
             #:cmd '("maak" "production-server")
             #:directory (byggsteg-managed-project-dir 'byggsteg)
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
            (auto-upgrade-capability)
            ;; Rotate service logs earlier than the Shepherd default and
            ;; keep a week of them: the same lines are in Loki, so the
            ;; local copies only need to bridge the time it takes to
            ;; notice that the stack itself is unhealthy.  This bounds
            ;; the disk cost of /var/log and /var/log/wolk-jjba.
            (modify-services %base-services
              (log-rotation-service-type config =>
                (log-rotation-configuration
                 (inherit config)
                 (size-threshold (* 20 1024 1024))
                 (expiry (* 7 24 3600))))))))))

wolk-jjba-os
