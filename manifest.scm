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

(use-modules (guix)
             (guix packages)
             (gnu packages guile)
             (gnu packages emacs)
             (gnu packages build-tools)
             (gnu packages guile-xyz))

(packages->manifest (list guile-3.0-latest
                          guile-ares-rs
                          emacs-no-x
                          (specification->package "gettext")
                          maak
                          coreutils))
