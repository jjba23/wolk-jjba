;;; main.scm

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
             (gnu packages admin)
             (gnu packages emacs)
             (gnu packages ssh)
             (gnu services networking)
             (gnu packages glib)
             (gnu packages ncurses)
             (gnu packages screen)
             (gnu packages version-control)
             (gnu packages shellutils)
             (gnu packages databases)
             (gnu packages docker)
             (gnu packages gcc)
             (gnu services nix)
             (gnu packages multiprecision)
             (gnu packages ssh)
             (gnu packages compression)
             (gnu packages rust-apps)
             (gnu packages avahi)
             (gnu services avahi)
             (gnu packages linux)
             (gnu packages sqlite)
             (gnu packages curl)
             (gnu packages disk)
             (gnu packages package-management)
             (gnu services dbus)
             (gnu services shepherd))

(use-service-modules networking desktop docker)
(use-package-modules certs)

(define wolk-jjba-filesystems
  (list (file-system
         (device "/dev/sda3")
         (mount-point "/")
         (type "ext4"))
        (file-system
         (device "/dev/sda1")
         (mount-point "/boot/efi")
         (type "vfat"))))

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
   curl
   git
   ripgrep
   net-tools
   dstat
   sqlite
   (specification->package "make")
   nix
   coreutils
   ))

(define wolk-jjba-joe-user-account
  (user-account
   (name "joe")
   (group "users")
   (supplementary-groups '("wheel" "docker" "input"))))

(operating-system
 (host-name "wolk-jjba")
 (timezone "Europe/Amsterdam")

 ;; (locale "en_US.utf8")
 (locale "nl_NL.utf8")

 (bootloader (bootloader-configuration
	      (bootloader grub-efi-bootloader)
	      (targets '("/boot/efi"))))
 

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
   (service nix-service-type)
   (service elogind-service-type)
   (service containerd-service-type)
   (service docker-service-type)
   %base-services
   )))



