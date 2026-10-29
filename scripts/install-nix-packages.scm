;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Developer tooling installed into the Nix profile, separate from the
;; Guix-managed system packages.  Storage and backups do not use an
;; object store: the Hetzner Storage Box is reached over SFTP/rsync and
;; CIFS, so no cloud CLI is installed here.
;;
;; Code:

(use-modules (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 readline)
             (wolk-jjba prelude))

(define (nix-profile-install x)
  (display (format #f "\n>>= installing nix package ~a\n" x))
  (syscall (format #f
                   (string-append "nix profile list | grep ~a ||"
                    " NIXPGS_ALLOW_UNFREE=1 nix -L profile install --impure nixpkgs#~a")
                   x x)))

(define wolk-jjba-nixpkgs
  '(stack sbt
          scala_2_13
          black
          pyright
          scala-cli
          onefetch
          mermaid-cli
          nixfmt
          rustfmt
          deadnix
          lua))

(for-each (lambda (x)
            (nix-profile-install x)) wolk-jjba-nixpkgs)
