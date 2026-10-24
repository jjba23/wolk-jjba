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
;; The maak task runner comes from the jointhefreeworld Guix channel (see
;; channels.scm) and is part of this list, because every application is
;; started through its own `maak production-server' task.  Taking it from
;; the channel rather than a copy in this repository means the server runs
;; the same release as the projects it starts.
;;
;; The Guile libraries in the collection -- kracht, scriba, veritas,
;; bewaking, hygguile, orgwebalchemy, the OpenAPI generator and the CSS
;; generator -- come from the same channel and are installed with it, so
;; the machine and the applications share one version of each library and
;; `maak guix-pull' moves both at once.
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
  #:use-module (jointhefreeworld packages applications)
  ;; The Guile libraries come from the same channel as maak.  They are
  ;; imported with a prefix on purpose: (gnu packages guile-xyz) exports
  ;; same-named older copies, and the `use-package-modules' call below adds
  ;; that module *after* this one, so unprefixed bindings would be the Guix
  ;; ones.  With the prefix the channel's release is the one in the list.
  #:use-module ((jointhefreeworld packages guile)
                #:prefix jtf:)
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
        ;; The collection's Guile library stack, from the channel: the same
        ;; release the cloned applications build and test against, installed
        ;; system-wide so scripts, `guile' sessions and the Shepherd daemons
        ;; see one set of libraries instead of whatever Guix last imported.
        jtf:guile-kracht
        jtf:guile-scriba
        jtf:guile-veritas
        jtf:guile-bewaking
        jtf:guile-hygguile
        jtf:guile-orgwebalchemy
        jtf:guile-openapi-generator
        jtf:guile-olive-css
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
        ;;
        ;; just is the task runner Byggsteg's `just-*' tasks and a
        ;; justfile checkout ask for (see (byggsteg job runners)).  A
        ;; job runs the runner it chose outside the project's own Guix
        ;; shell -- the shell is what the project's `test' target may
        ;; start, not what starts `just' -- so the machine has to have
        ;; it, like make.  Other runners (cargo, dune, task, mask, rake)
        ;; are the same one line here when a project needs one.
        just
        (specification->package "make")
        sysstat
        openssl
        net-tools
        cifs-utils
        icecast
        (specification->package "gettext")
        passt))
