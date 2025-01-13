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
             (wolk-jjba certbot)
             (wolk-jjba packages)
             (wolk-jjba minecraft)
             (wolk-jjba byggsteg)
             (wolk-jjba wikimusic)
             (wolk-jjba crons))

(use-service-modules networking
                     desktop
                     ssh
                     avahi
                     nix
                     web
                     dbus)

(define wolk-jjba-filesystems
  (list (file-system
          ;; UUID can only be obtained after Guix installation
          (device (uuid "05c98e2c-cdfd-4b41-8719-e82354529d8a"))
          (mount-point "/")
          (type "ext4"))))

(define wolk-jjba-subuid
  (simple-service 'podman-subuid-subgid
                  ;; If subuid/subgid will be needed somewhere else, the service must be
                  ;; created to handle it.
                  etc-service-type
                  `(("subuid" ,(plain-file "subuid"
                                           (string-append "root"
                                                          ":100000:65536\n")))
                    ("subgid" ,(plain-file "subgid"
                                           (string-append "root"
                                                          ":100000:65536\n"))))))

(define wolk-jjba-joe-user-account
  (user-account
    (name "joe")
    (group "users")
    (supplementary-groups '("wheel" "netdev" "audio" "video" "input"))))

(define wolk-jjba-ssh-service
  (service openssh-service-type
           (openssh-configuration (openssh openssh-sans-x)
                                  (password-authentication? #f)
                                  (port-number 2323)
                                  (max-connections 23)
                                  (authorized-keys `(("joe" ,(local-file
                                                              "/home/joe/.ssh/wolk-jjba.pub")))))))

;; TODO harden security + firewall
(define wolk-jjba-iptables
  (service iptables-service-type
           (iptables-configuration)))

(define (syscall cmd)
  (let* ((process (open-input-pipe cmd))
         (process-output (get-string-all process)))
    (close-pipe process)
    (display process-output) process-output))

(define (nix-profile-install x)
  (syscall (format #f
            "nix -L --extra-experimental-features 'nix-command flakes' profile install --impure nixpkgs#~a"
            x)))

;;
;;
;; start run
;;

;; (display "\n>>= installing nix packages\n")
;; (for-each (lambda (x)
;;             (nix-profile-install x))
;;           '("stack" "sbt"))

(operating-system
 (host-name "wolk-jjba")
 (timezone "Europe/Amsterdam")
 (locale "nl_NL.utf8")
 (keyboard-layout (keyboard-layout "us"))

 (bootloader (bootloader-configuration
              (bootloader grub-bootloader)
              (targets '("/dev/sda"))))

 (kernel-arguments (list "console=ttyS0,115200"))
 (sudoers-file (plain-file "sudoers" (string-join '("root ALL=(ALL) NOPASSWD:ALL"
                                                    "%wheel ALL=(ALL) NOPASSWD:ALL"
                                                    "joe ALL=(ALL) NOPASSWD:ALL") "\n")))
 (initrd-modules (append (list "virtio_scsi") %base-initrd-modules))
 (file-systems (append wolk-jjba-filesystems %base-file-systems))

 (users (cons* wolk-jjba-joe-user-account %base-user-accounts))

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
         wolk-jjba-subuid
         wolk-jjba-iptables
         (service nix-service-type)
         (service elogind-service-type)
         (service network-manager-service-type)
         (service wpa-supplicant-service-type)
         (service modem-manager-service-type)
         wolk-jjba-certbot

         (service nginx-service-type
                  (nginx-configuration (server-blocks (list
                                                       wolk-jjba-base-nginx-conf
                                                       wolk-jjba-jointhefreeworld-nginx-conf
                                                       wolk-jjba-carvoeirowaterfun-nginx-conf
                                                       wolk-jjba-casadelcata-nginx-conf
                                                       wolk-jjba-byggsteg-nginx-conf
                                                       wolk-jjba-wikimusic-api-nginx-conf
                                                       wolk-jjba-wikimusic-ssr-nginx-conf))
                                       (upstream-blocks (list (nginx-upstream-configuration
                                                               (name
                                                                "byggsteg-proxy")
                                                               (servers (list
                                                                         "127.0.0.1:50002")))
                                                              (nginx-upstream-configuration
                                                               (name
                                                                "wikimusic-api-proxy")
                                                               (servers (list
                                                                         "127.0.0.1:50050")))
                                                              (nginx-upstream-configuration
                                                               (name
                                                                "wikimusic-ssr-proxy")
                                                               (servers (list
                                                                         "127.0.0.1:6923")))))))
         (service wolk-jjba-byggsteg-service-type)
         (service wolk-jjba-minecraft-server-service-type)
         (service wolk-jjba-wikimusic-ssr-service-type)
         (service wolk-jjba-wikimusic-api-service-type)
         wolk-jjba-cron-jobs-service
         %base-services)))

