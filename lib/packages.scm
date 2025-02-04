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

(define-module (wolk-jjba packages)
  #:use-module (gnu)
  #:use-module (guix packages)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system guile)
  #:use-module (guix git-download)
  #:use-module (guix)
  #:use-module (gnu packages ssh)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 time)
  #:use-module (ice-9 format)
  #:use-module (ice-9 string-fun)
  #:use-module (ice-9 iconv)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (ice-9 threads))

(use-package-modules base
                     idutils
                     certs
                     guile-xyz
                     guile
                     bash
                     nss
                     pkg-config
                     rust
                     admin
                     autotools
                     emacs
                     perl
                     ssh
                     containers
                     glib
                     texinfo
                     ncurses
                     gnupg
                     node
                     screen
                     version-control
                     shellutils
                     databases
                     gcc
                     python
                     multiprecision
                     ssh
                     guile-xyz
                     compression
                     rust-apps
                     terminals
                     avahi
                     linux
                     vim
                     sqlite
                     curl
                     disk
                     package-management)

(define-public wolk-jjba-system-packages
  (list (specification->package "openjdk@21.0.2")
        htop
        emacs-next
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
        rust
        rust-cargo
        (specification->package "go@1.23")
        curl
        git
        ripgrep
        net-tools
        libltdl
        dstat
        sqlite
        autoconf
        python
        (specification->package "node@20.18.1")
        fzf
        (specification->package "make")
        nix
        coreutils
        perl
        texinfo
        slirp4netns
        podman
        podman-compose
        (specification->package "gettext")
        passt
        ))

