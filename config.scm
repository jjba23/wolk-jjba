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
             (ice-9 threads))

(use-modules (guix git-download)
             (gnu packages ssh)
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
             (wolk-jjba crons))

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
  "nl_NL.utf8")

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
          (type "vfat"))))

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
    (supplementary-groups '("wheel" "netdev" "audio" "video" "input" "cgroup" "mpd"))))

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

(define wolk-jjba-mpd-service
  (service mpd-service-type
           (mpd-configuration (outputs (list (mpd-output (name "streaming")
                                                         (type "httpd")
                                                         (extra-options `((encoder . "flac")
                                                                          (format . "44100:16:2")
                                                                          (port . "6690"))))))
                              (decoders (list (mpd-plugin (plugin "mikmod")
                                                          (enabled? #t))
                                              (mpd-plugin (plugin "openmpt")
                                                          (enabled? #t)
                                                          (extra-options `((repeat-count . -1)
                                                                           (interpolation-filter . 1))))))
                              (resampler (mpd-plugin (plugin "libsamplerate")
                                                     (extra-options `((type . 0)))))
                              (music-directory "/mnt/music"))))

(define wolk-jjba-mympd-service
  (service mympd-service-type
         (mympd-configuration
          (port 6680))))

(define sshfs-music-service
  (simple-service 'sshfs-music-mount shepherd-root-service-type
                  (list (shepherd-service (provision '(sshfs-music))
                                          (requirement '(networking))
                                          (documentation
                                           "Mount remote music directory via SSHFS.")
                                          (start #~(make-forkexec-constructor (list
                                                                               "/run/current-system/profile/bin/sshfs"
                                                                               "wolkenschlosslagerung:/home/music"
                                                                               "/mnt/music"
                                                                               "-C"
                                                                               "-o"
                                                                               "allow_other"
                                                                               "-o"
                                                                               "idmap=user"
                                                                               "-f")
                                                    #:user "backer-upper"
                                                    #:group "users"))
                                          (stop #~(make-kill-destructor))
                                          (respawn? #t)))))

(define wolk-jjba-os
  (operating-system
    (host-name "wolk-jjba")
    (timezone "Europe/Amsterdam")
    (locale wolk-jjba-locale)
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
    (users (cons* wolk-jjba-minecraft-daemon-user-account
                  wolk-jjba-backer-upper-user-account
                  wolk-jjba-joe-user-account
                  wolk-jjba-byggsteg-runner-user-account %base-user-accounts))

    (packages (append wolk-jjba-system-packages %base-packages))

    (services
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
            wolk-jjba-mpd-service
            wolk-jjba-mympd-service
            sshfs-music-service
            wolk-jjba-iptables-service
            (service mail-aliases-service-type
                     '(("postmaster" "joe")
                       ("joe" "jjbigorra@gmail.com")))
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
            ;; (service nix-service-type
            ;; (nix-configuration (extra-config (list
            ;; "experimental-features = nix-command flakes"))))
            (service elogind-service-type)
            (service network-manager-service-type)
            (service postgresql-service-type
                     (postgresql-configuration (postgresql postgresql-16)))
            (service wpa-supplicant-service-type)
            (service prometheus-node-exporter-service-type)
            (service modem-manager-service-type)
            (nginx-capability #:minimal-conf #f)
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
            (cron-jobs-capability)
            %base-services))))

wolk-jjba-os
