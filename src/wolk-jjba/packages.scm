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
;; System-wide packages.  These are available to root, to the Shepherd
;; daemons and to the applications cloned under
;; /etc/byggsteg/job-clone: Guile and its build dependencies, the
;; database and archive tools used by the backup jobs, OpenSSL, CIFS
;; utilities for the Hetzner Storage Box, Icecast, and assorted CLI
;; utilities.
;;
;; The maak task runner is defined in (wolk-jjba maak) and is part of
;; this list, because every application is started through its own
;; `maak production-server' task.
;;
;; Code:

(define-module (wolk-jjba packages)
  #:use-module (gnu)
  #:use-module (guix packages)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system guile)
  #:use-module (guix git-download)
  #:use-module (guix)
  #:use-module (gnu packages ssh)
  #:use-module (wolk-jjba maak)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 time)
  #:use-module (ice-9 format)
  #:use-module (ice-9 string-fun)
  #:use-module (ice-9 iconv)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (ice-9 threads))

(use-package-modules admin
                     autotools
                     avahi
                     base
                     bash
                     certs
                     compression
                     containers
                     curl
                     databases
                     disk
                     emacs
                     gcc
                     glib
                     gnupg
                     guile
                     guile-xyz
                     idutils
                     linux
                     mpd
                     multiprecision
                     node
                     ncurses
                     node
                     samba
                     nss
                     package-management
                     perl
                     pkg-config
                     python
                     rsync
                     rust-apps
                     screen
                     shells
                     shellutils
                     sqlite
                     ssh
                     ssh
                     terminals
                     texinfo
                     tls
                     version-control
                     vim
                     xiph
                     web)

(define-public wolk-jjba-system-packages
  (list (specification->package "openjdk@25")
        htop
        emacs-no-x
        openssh
        dbus
        ncurses
        screen
        tar
        zip
        unzip
        sshfs
        mpd-mpc
        gmp
        gcc
        glibc-locales
        guile-3.0-latest
        kitty
        xxd
        curl
        rsync
        git
        maak
        ripgrep
        net-tools
        libltdl
        dstat
        sqlite
        fish
        autoconf
        python
        httpd
        node
        nss
        fzf
        nix
        coreutils
        perl
        texinfo
        podman-compose
        ;; Rootless Podman itself is installed by
        ;; `rootless-podman-service-type' (see config.scm), and the
        ;; rest of a working rootless setup -- fuse-overlayfs,
        ;; slirp4netns and the `docker' command that is Podman -- is
        ;; installed by (containers-capability), which is where those
        ;; three belong: they are the capability's, not a package list's.
        sysstat
        openssl
        net-tools
        cifs-utils
        icecast
        (specification->package "gettext")
        passt))
