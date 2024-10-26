;;; home.scm

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

(use-modules (gnu home)
             (gnu home services)
             (gnu home services shells)
             (gnu packages emacs)
             (gnu packages admin)
             (gnu services)
             (guix gexp))
(use-modules (gnu home services ssh)
             (gnu home services gnupg)
             (gnu packages gnupg))
(use-modules (gnu home services sound)
             (gnu home services desktop))

(define wolk-jjba-home-files-service
  (service home-files-service-type
	   `((".config/nix/nix.conf" ,(local-file "nix/nix.conf"))
             (".config/nixpkgs/config.nix" ,(local-file "nix/nixpkgs.nix"))
             )))

(display "\n>>= configuring home environment...\n")
(home-environment
 (packages
  (list pfetch)) 
 (services
  (list 
   (service home-dbus-service-type)
   wolk-jjba-home-files-service
   )))
