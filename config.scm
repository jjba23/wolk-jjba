;;; config.scm

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
             (guix packages)
             (gnu services networking)
             (gnu packages admin)
             (gnu packages emacs)
             (gnu packages ssh)
             (gnu packages glib)
             (gnu packages ncurses)
             (gnu packages node)
             (gnu packages screen)
             (gnu packages version-control)
             (gnu packages shellutils)
             (gnu packages databases)
             (gnu packages docker)
             (gnu packages gcc)
             (gnu services nix)
             (gnu packages multiprecision)
             (gnu packages ssh)
             (gnu packages guile-xyz)
             (gnu packages compression)
             (gnu packages rust-apps)
             (gnu packages terminals)
             (gnu packages avahi)
             (gnu services avahi)
             (gnu packages guile)
             (gnu packages linux)
             (gnu packages sqlite)
             (gnu packages curl)
             (gnu packages disk)
             (gnu services web)
             (gnu services certbot)
             (gnu packages package-management)
             (gnu services dbus)
             (gnu services shepherd))


(use-service-modules networking desktop docker ssh)
(use-package-modules certs)

(define wolk-jjba-filesystems
  (list   
   (file-system
    (device (uuid "05c98e2c-cdfd-4b41-8719-e82354529d8a"))
    (mount-point "/")
    (type "ext4"))))


(define wolk-jjba-system-packages
  (list
   (specification->package "openjdk@21.0.2")
   htop
   emacs
   openssh
   dbus
   ncurses
   screen
   tar
   zip unzip
   gmp
   gcc
   guile
   guile-fibers
   kitty
   curl
   git
   ripgrep
   net-tools
   dstat
   sqlite
   (specification->package "node@18.19.0")
   fzf
   (specification->package "make")
   nix
   coreutils
   ))

(define wolk-jjba-joe-user-account
  (user-account
   (name "joe")
   (group "users")
   (supplementary-groups '("wheel" "netdev" "audio" "video" "docker" "input"))))

(define wolk-jjba-ssh-service
  (service openssh-service-type
           (openssh-configuration
            (openssh openssh-sans-x)
            (password-authentication? #false)
            (authorized-keys
             `(("joe" ,(local-file "/home/joe/.ssh/wolk-jjba.pub")))))))

(define %nginx-deploy-hook
  (program-file
   "nginx-deploy-hook"
   #~(let ((pid (call-with-input-file "/var/run/nginx/pid" read)))
       (kill pid SIGHUP))))

(define wolk-jjba-base-nginx-conf
  (nginx-server-configuration
   (listen '("80"))
   (server-name '("jointhefreeworld.org" "www.jointhefreeworld.org"
                  "casadelcata.es" "www.casadelcata.es"
                  "carvoeirowaterfun.com" "www.carvoeirowaterfun.com"))
   (root "/srv/http")))

(define wolk-jjba-jointhefreeworld-nginx-conf
  (nginx-server-configuration
   (listen '("443 ssl"))
   (server-name '("jointhefreeworld.org" "www.jointhefreeworld.org"))
   (ssl-certificate "/etc/letsencrypt/live/jointhefreeworld.org/fullchain.pem")
   (ssl-certificate-key "/etc/letsencrypt/live/jointhefreeworld.org/privkey.pem")
   (root "/srv/http/jointhefreeworld.org")))

(define wolk-jjba-jointhefreeworld-certbot-cert
  (certificate-configuration
   (domains '("jointhefreeworld.org" "www.jointhefreeworld.org"))
   (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-carvoeirowaterfun-nginx-conf
  (nginx-server-configuration
   (listen '("443 ssl"))
   (server-name '("carvoeirowaterfun.com" "www.carvoeirowaterfun.com"))
   (ssl-certificate "/etc/letsencrypt/live/carvoeirowaterfun.com/fullchain.pem")
   (ssl-certificate-key "/etc/letsencrypt/live/carvoeirowaterfun.com/privkey.pem")
   (root "/srv/http/carvoeirowaterfun.com")))

(define wolk-jjba-carvoeirowaterfun-certbot-cert
  (certificate-configuration
   (domains '("carvoeirowaterfun.com" "www.carvoeirowaterfun.com"))
   (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-casadelcata-nginx-conf
  (nginx-server-configuration
   (listen '("443 ssl"))
   (server-name '("casadelcata.es" "www.casadelcata.es"))
   (ssl-certificate "/etc/letsencrypt/live/casadelcata.es/fullchain.pem")
   (ssl-certificate-key "/etc/letsencrypt/live/casadelcata.es/privkey.pem")
   (root "/srv/http/casadelcata.es")))

(define wolk-jjba-casadelcata-certbot-cert
  (certificate-configuration
   (domains '("casadelcata.es" "www.casadelcata.es"))
   (deploy-hook %nginx-deploy-hook)))

;; You may want to use a staging ACME server when testing.
;; (define %certbot-server
;;   "https://acme-staging-v02.api.letsencrypt.org/directory")

(define (wolk-jjba-byggsteg-service config)
  (list
   (shepherd-service
    (documentation "Run byggsteg as a daemon")
    (provision '(byggsteg))
    (requirement '())
    (start #~(make-forkexec-constructor
              '("/run/current-system/profile/bin/make" "server")
              #:directory "/var/log/byggsteg/job-clone/byggsteg/trunk" ))
    (stop #~(make-kill-destructor))
    (auto-start? #t)
    (respawn? #t)
    )))

(define wolk-jjba-byggsteg-service-type
  (service-type
   (name 'byggsteg)
   (description "Run byggsteg as a daemon")
   (extensions
    (list (service-extension
           shepherd-root-service-type
           wolk-jjba-byggsteg-service)))
   (default-value '())
   ))

(operating-system
 (host-name "wolk-jjba")
 (timezone "Europe/Amsterdam")

 ;; (locale "en_US.utf8")
 (locale "nl_NL.utf8")
 (keyboard-layout (keyboard-layout "us"))

 (bootloader (bootloader-configuration
	      (bootloader grub-bootloader)
	      (targets '("/dev/sda"))))

 (kernel-arguments
  (list "console=ttyS0,115200"))
 (sudoers-file (local-file "system/sudoers"))
 (initrd-modules (append (list "virtio_scsi")
                         %base-initrd-modules)) 
 (file-systems
  (append
   wolk-jjba-filesystems
   %base-file-systems))
 
 (users
  (cons* wolk-jjba-joe-user-account
         %base-user-accounts))
 
 (packages
  (append wolk-jjba-system-packages
          %base-packages))
 
 (services
  (cons*
   (service dbus-root-service-type)
   (service avahi-service-type)
   (service udisks-service-type)
   (service upower-service-type)
   (service accountsservice-service-type)
   (service ntp-service-type)
   wolk-jjba-ssh-service
   (service nix-service-type)
   (service elogind-service-type)
   (service network-manager-service-type)
   (service wpa-supplicant-service-type)
   (service modem-manager-service-type)
   (service containerd-service-type)
   (service docker-service-type)
   (service certbot-service-type
            (certbot-configuration
             (email "jjbigorra@gmail.com")
             (webroot "/srv/http")
             (certificates
              (list
               wolk-jjba-casadelcata-certbot-cert
               wolk-jjba-jointhefreeworld-certbot-cert
               wolk-jjba-carvoeirowaterfun-certbot-cert
               ))))
   
   (service nginx-service-type
            (nginx-configuration
             (server-blocks
              (list
               wolk-jjba-base-nginx-conf
               wolk-jjba-jointhefreeworld-nginx-conf
               wolk-jjba-carvoeirowaterfun-nginx-conf
               wolk-jjba-casadelcata-nginx-conf
               ))))
   (service wolk-jjba-byggsteg-service-type)
   %base-services
   )))



