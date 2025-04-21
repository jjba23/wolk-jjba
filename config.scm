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

;; auto-load all modules in ./lib/
(load "./lib/path.scm")
(use-modules (wolk-jjba path))
(load-lib-modules)

(use-modules (guix git-download)
             (gnu packages ssh)
             (gnu packages package-management)
             ((guix licenses)
              #:prefix license:)
             (guix build-system gnu)
             (wolk-jjba nginx)
             (gnu system accounts)
             (wolk-jjba certbot)
             (wolk-jjba packages)
             (wolk-jjba minecraft)
             (wolk-jjba byggsteg)
             (wolk-jjba iptables)
             (wolk-jjba lucidplan)
             (wolk-jjba wikimusic)
             (wolk-jjba crons))

(use-package-modules shells monitoring)

(use-service-modules networking
                     desktop
                     ssh
                     avahi
                     admin
                     monitoring
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

(define wolk-jjba-backer-upper-user-account
  (user-account
    (name "backer-upper")
    (group "users")
    (supplementary-groups '("netdev" "audio" "video" "input"))))

(define wolk-jjba-zabbix-front-end-configuration-nginx
  (nginx-server-configuration (root #~(string-append #$zabbix-server:front-end
                                                     "/share/zabbix/php"))
                              (index '("index.php"))
                              (locations (let ((php-location (nginx-php-location)))
                                           (list (nginx-location-configuration
                                                  (inherit php-location)
                                                  (body (append (nginx-location-configuration-body
                                                                 php-location)
                                                                (list
                                                                 "
fastcgi_param PHP_VALUE \"post_max_size = 16M
                          max_execution_time = 300\";
")))))))
                              (listen '("50180"))))

(define wolk-jjba-ssh-service
  (service openssh-service-type
           (openssh-configuration (openssh openssh-sans-x)
                                  (password-authentication? #f)
                                  (port-number 2323)
                                  (max-connections 12))))

(define (syscall cmd)
  (let* ((process (open-input-pipe cmd))
         (process-output (get-string-all process)))
    (close-pipe process)
    (display process-output) process-output))

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
                                          "joe ALL=(ALL) NOPASSWD:ALL") "\n")))
 (initrd-modules (append (list "virtio_scsi") %base-initrd-modules))
 (file-systems (append wolk-jjba-filesystems %base-file-systems))

 (users (cons* wolk-jjba-minecraft-daemon-user-account
               wolk-jjba-backer-upper-user-account wolk-jjba-joe-user-account
               %base-user-accounts))

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
         (service rootless-podman-service-type
                  (rootless-podman-configuration (subgids (list (subid-range (name
                                                                              "joe"))))
                                                 (subuids (list (subid-range (name
                                                                              "joe"))))))
         (service unattended-upgrade-service-type)
         (service nix-service-type)
         (service elogind-service-type)
         (service network-manager-service-type)
         (service wpa-supplicant-service-type)
         (service prometheus-node-exporter-service-type)
         (service zabbix-server-service-type
                  (zabbix-server-configuration (include-files '("/root/secrets/zabbix-php"))))
         (service zabbix-front-end-service-type
                  (zabbix-front-end-configuration (db-secret-file
                                                   "/root/secrets/zabbix")
                                                  (nginx (list
                                                          wolk-jjba-zabbix-front-end-configuration-nginx))))
         (service modem-manager-service-type)
         (wolk-jjba-nginx #:minimal-conf #f)
         wolk-jjba-certbot
         (service wolk-jjba-byggsteg-service-type)
         (service wolk-jjba-lucidplan-service-type)
         (service wolk-jjba-minecraft-server-service-type)
         (service wolk-jjba-wikimusic-service-type)
         wolk-jjba-cron-jobs-service
         %base-services)))

