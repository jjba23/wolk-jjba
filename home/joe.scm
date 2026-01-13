;;; home.scm

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

(use-modules (gnu home)
             (gnu home services)
             (gnu home services shells)
             (gnu packages emacs)
             (gnu packages admin)
             (gnu packages)
             (gnu services containers)
             (gnu home services containers)
             (gnu packages ssh)
             (gnu services)
             (guix gexp))
(use-modules (gnu home services ssh)
             (gnu home services gnupg)
             (gnu packages gnupg))

(define wolk-jjba-home-files-service
  (service home-files-service-type
           `((".config/nix/nix.conf" ,(local-file "nix/nix.conf"))
             (".config/nixpkgs/config.nix" ,(local-file "nix/nixpkgs.nix")))))

(define wolk-jjba-fancy-bash-service
  (simple-service 'wolk-jjba-fancy-bash home-bash-service-type
                  (home-bash-extension (environment-variables '())
                                       (bashrc `(,(local-file "bash/bashrc.sh"))))))

(define wolk-jjba-home-vars-service
  (simple-service 'some-useful-env-vars-service
                  home-environment-variables-service-type
                  `(("SBCL_HOME" . "$HOME/.guix-home/profile/lib/sbcl")
                    ("GUIX_LOCPATH" . "$HOME/.guix-profile/lib/locale")
                    ("LANG" . "nl_NL.UTF-8")
                    ("LANGUAGE" . "nl_NL"))))

(define wolk-jjba-home-oci-provisioning
  (simple-service 'home-oci-provisioning home-oci-service-type
                  (oci-extension (volumes (list (oci-volume-configuration (name
                                                                           "prometheus"))
                                                (oci-volume-configuration (name
                                                                           "grafana"))))
                                 (networks (list (oci-network-configuration (name
                                                                             "monitoring"))))
                                 (containers (list (oci-container-configuration
                                                    (image "prom/prometheus:latest")
                                                    (network "monitoring")
                                                    (ports '(("9000" . "9000")
                                                             ("9090" . "9090")))
                                                    (volumes (list '("prometheus:/var/lib/prometheus"))))
                                                   (oci-container-configuration
                                                    (image "nginx:trixie-pearl")
                                                    (network "monitoring")
                                                    (ports '(("58080" . "80")
                                                             ))
                                                    (volumes (list '("prometheus:/var/lib/prometheus"))))
                                                   (oci-container-configuration
                                                    (image
                                                     "grafana/grafana:main")
                                                    (network "monitoring")
                                                    (volumes '("grafana:/var/lib/grafana"))))))))

;; (oci-container-configuration
;;                                                     (network "monitoring")
;;                                                     (image (oci-image (repository
;;                                                                        "guile")
;;                                                                       (tag "3")
;;                                                                       (value (specifications->manifest '
;;                                                                               ("guile")))
;;                                                                       (pack-options '
;;                                                                        (#:symlinks
;;                                                                         (("/bin/guile"
;;                                                                           ->
;;                                                                           "bin/guile"))
;;                                                                         #:max-layers
;;                                                                         2))))
;;                                                     (entrypoint "/bin/guile")
;;                                                     (command '("-c"
;;                                                                "(display \"hello!\n\")")))

(display "\n>>= configuring home environment...\n")
(home-environment
  (services
   (append (list wolk-jjba-home-files-service wolk-jjba-home-vars-service
                 wolk-jjba-home-oci-provisioning wolk-jjba-fancy-bash-service)
           %base-home-services)))

