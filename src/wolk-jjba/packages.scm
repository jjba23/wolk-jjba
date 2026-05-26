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
                     multiprecision
                     node
                     ncurses
                     node
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
        gmp
        gcc
        (specification->package "guile")
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
        (specification->package "make")
        nix
        coreutils
        perl
        texinfo
        podman-compose
        sysstat
        openssl
        net-tools
        (specification->package "gettext")
        passt))
