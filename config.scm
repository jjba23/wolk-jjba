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
             (gnu packages package-management)
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
                     admin
                     databases
                     monitoring
                     mail
                     containers
                     nix
                     web
                     dbus)

(define wolk-jjba-filesystems
  (list (file-system
          (device "/dev/sda3")
          (mount-point "/")
          (type "ext4"))))

(define wolk-jjba-joe-user-account
  (user-account
    (name "joe")
    (group "users")
    (home-directory "/home/joe")
    (comment "Josep Bigorra's account")
    (supplementary-groups '("wheel" "netdev" "audio" "video" "input" "cgroup"))))

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
    (supplementary-groups '("netdev" "audio" "video" "input"))))

(define wolk-jjba-ssh-service
  (service openssh-service-type
           (openssh-configuration (openssh openssh-sans-x)
                                  (password-authentication? #f)
                                  (port-number 2323)
                                  (max-connections 12))))

(define wolk-jjba-exim-service
  (service exim-service-type
           (exim-configuration (config-file (local-file "./my-exim.conf")))))

(define wolk-jjba-os
  (operating-system
    (host-name "wolk-jjba")
    (timezone "Europe/Amsterdam")
    (locale "nl_NL.utf8")
    (keyboard-layout (keyboard-layout "us"))

    (bootloader (bootloader-configuration
                  (bootloader grub-bootloader)
                  (targets '("/dev/sda"))))

    (sudoers-file (plain-file "sudoers"
                              (string-join '("root ALL=(ALL) NOPASSWD:ALL"
                                             "%wheel ALL=(ALL) NOPASSWD:ALL"
                                             "joe ALL=(ALL) NOPASSWD:ALL")
                                           "\n")))
    (initrd-modules (append (list "virtio_scsi") %base-initrd-modules))
    (file-systems (append wolk-jjba-filesystems %base-file-systems))

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
            wolk-jjba-iptables-service
            wolk-jjba-exim-service
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
            (service nix-service-type
                     (nix-configuration (extra-config (list
                                                       "experimental-features = nix-command flakes"))))
            (service elogind-service-type)
            (service network-manager-service-type)
            (service postgresql-service-type
                     (postgresql-configuration (postgresql postgresql-16)))
            (service wpa-supplicant-service-type)
            (service prometheus-node-exporter-service-type)
            (service modem-manager-service-type)
            (nginx-capability #:minimal-conf #f)
            (service wolk-jjba-minecraft-server-service-type)
            (certbot-capability)
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
            ;; (make-guile-server-shepherd-daemon #:service-name 'oculuslambda-daemon
            ;;  #:provision '(oculuslambda-daemon)
            ;;  #:cmd '("make" "production-server")
            ;;  #:directory (byggsteg-managed-project-dir 'oculuslambda)
            ;;  #:documentation "Run OculusLambda as a Herd/Shepherd daemon")
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

