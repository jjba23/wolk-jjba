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
             (".config/nixpkgs/config.nix" ,(local-file "nix/nixpkgs.nix"))
             (".config/alloy/config.alloy" ,(local-file "config.alloy")))))

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

(define wolk-jjba-home-oci
  (service home-oci-service-type
           (for-home (oci-configuration (user "joe")
                                        (runtime 'podman)
                                        (verbose? #t)))))

(define wolk-jjba-home-oci-provisioning
  (simple-service 'home-oci-provisioning home-oci-service-type
                  (oci-extension (volumes (list (oci-volume-configuration (name
                                                                           "prometheus"))
                                                (oci-volume-configuration (name
                                                                           "grafana"))))
                                 (networks (list (oci-network-configuration (name
                                                                             "monitoring"))))

                                 (containers (list (oci-container-configuration
                                                    (image
                                                     "grafana/loki:latest")
                                                    (ports '(("53100" . "3100")))
                                                    (network "monitoring")
                                                    (volumes (list
                                                              "loki-config.yml:/etc/loki/loki-config.yaml")))
                                                   (oci-container-configuration
                                                    (image
                                                     "grafana/alloy:latest")
                                                    (network "monitoring")
                                                    (ports '(("12345" . "12345"))) 
                                                    (volumes (list
                                                              "alloy:/var/lib/alloy/data"
                                                              "/home/joe/.config/alloy/config.alloy:/etc/alloy/config.alloy"
                                                              "/var/log:/var/log:ro"
                                                              )))
                                                   (oci-container-configuration
                                                    (image
                                                     "prom/prometheus:latest")
                                                    (network "monitoring")
                                                    (ports '(("59000" . "9000")
                                                             ("59090" . "9090")))
                                                    (volumes (list
                                                              "prometheus:/var/lib/prometheus")))
                                                   (oci-container-configuration
                                                    (image "nginx/nginx-prometheus-exporter:1.5.1")
                                                    (network "host")
                                                    (ports '(("9113" . "9113")))
                                                    ;; curl http://127.0.0.1:81/nginx_status
                                                   ;; docker run -p 9113:9113 nginx/nginx-prometheus-exporter:1.5.1 
                                                    (extra-arguments '("--nginx.scrape-uri=http://127.0.0.1:81/nginx_status")))
                                                   (oci-container-configuration
                                                    (image
                                                     "grafana/grafana:main")
                                                    (network "monitoring")
                                                    (ports '(("53000" . "3000")
                                                             ("53000" . "3000")))
                                                    (environment '(("GF_LIVE_ALLOWED_ORIGINS" . "https://grafana.jointhefreeworld.org")
                                                                   ("GF_CORS_ALLOWED_ORIGINS" . "https://grafana.jointhefreeworld.org")
                                                                   ("GF_SECURITY_CSRF_TRUSTED_ORIGINS" . "grafana.jointhefreeworld.org")
                                                                   ("GF_SERVER_DOMAIN" . "grafana.jointhefreeworld.org")
                                                                   ("GF_SERVER_ROOT_URL" . "https://grafana.jointhefreeworld.org")))
                                                    (volumes '("grafana:/var/lib/grafana"))))))))

(display "\n>>= configuring home environment...\n")
(home-environment
  (services
   (append (list wolk-jjba-home-files-service wolk-jjba-home-vars-service
                 wolk-jjba-home-oci wolk-jjba-home-oci-provisioning
                 wolk-jjba-fancy-bash-service) %base-home-services)))

