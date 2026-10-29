;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Upgrade every package in the Nix profile.  The profile itself is
;; created by install-nix-packages.scm.
;;
;; Code:

(use-modules (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 readline)
             (wolk-jjba prelude))

(syscall "NIXPGS_ALLOW_UNFREE=1 nix profile upgrade --impure '.*'")
