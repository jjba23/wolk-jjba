;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; The development shell: Guile, the test suite and guix itself.  The
;; collection's packages come from the jointhefreeworld channel pinned in
;; channels.scm, not from copies defined here, so a version is bumped once,
;; in the channel, and every `maak test' and `guix time-machine
;; --channels=channels.scm' run picks it up.
;;
;; The channel modules are imported with a prefix because Guix still
;; carries older guile-veritas and maak bindings; the prefix makes it
;; explicit which release the shell gets instead of leaving it to import
;; order.

(use-modules (guix packages)
             (guix profiles)
             (gnu packages)
             (gnu packages base)
             (gnu packages emacs)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages package-management)
             ((jointhefreeworld packages guile)
              #:prefix jtf:)
             ((jointhefreeworld packages applications)
              #:prefix jtf:))

;; guix itself is here for the test suite: the specs import (guix gexp)
;; and (gnu services ...) to inspect the very records config.scm builds.
;;
;; guile-dokgen and texinfo are the API documentation: `dokgen' reads the
;; docstrings of the modules under src/wolk-jjba and writes the chapter in
;; Texinfo, `texi2any' renders it as one HTML page.  Both are named as
;; specifications so the channel's release is the one the shell gets.
(packages->manifest (list guile-3.0-latest
                          guile-ares-rs
                          jtf:guile-veritas
                          guix
                          emacs-no-x
                          (specification->package "gettext")
                          (specification->package "guile-dokgen")
                          (specification->package "texinfo")
                          jtf:maak
                          coreutils))
