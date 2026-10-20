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
;; Upgrade every package in the Nix profile.  The profile itself is
;; created by install-nix-packages.scm.
;;
;; Code:

(use-modules (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 readline)
             (wolk-jjba prelude))

(syscall "NIXPGS_ALLOW_UNFREE=1 nix profile upgrade --impure '.*'")
