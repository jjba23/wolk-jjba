;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Guix Home environment for user `joe'.  It installs the bash setup
;; and the Nix configuration.  The observability stack is not part of
;; Guix Home: Prometheus, Loki, Grafana and Alloy are native Guix
;; System services, see (wolk-jjba monitoring).
;;
;; The bashrc is generated, not checked in: (wolk-jjba bash) supplies the
;; machine identity and the language data (greetings, git shortcuts, this
;; server's helpers), and bash/shell-lib.bash is spliced in verbatim as the
;; shared prompt and helper library.  Change those, then `maak jr'.
;;
;; Reconfigure it with `maak jr' or:
;;   guix home reconfigure -L ./src home/joe.scm --fallback
;;
;; Code:

(use-modules (gnu home)
             (gnu home services)
             (gnu home services shells)
             (gnu packages emacs)
             (gnu packages admin)
             (gnu packages)
             (gnu packages ssh)
             (gnu services)
             (guix gexp))
(use-modules (gnu home services ssh)
             (gnu home services gnupg)
             (gnu packages gnupg)
             (wolk-jjba bash))

(define wolk-jjba-home-files-service
  (service home-files-service-type
           `((".config/nix/nix.conf" ,(local-file "nix/nix.conf"))
             (".config/nixpkgs/config.nix" ,(local-file "nix/nixpkgs.nix"))
             ;; Emacs key bindings for the pager; less(1) 582+ reads this
             ;; source file directly, no lesskey compile step involved.
             (".config/lesskey" ,(local-file "bash/lesskey")))))

;; ~/.bashrc, assembled from the same kinds of source as the other two
;; machines: data from Scheme, the shared library read from the checkout, and
;; nothing hand-written.  Every piece is handed to `mixed-text-file' as a
;; string: given a file-like object it writes that object's store path into the
;; text, so the library is spliced in as its contents instead.
(define wolk-jjba-bashrc
  (mixed-text-file "bashrc.sh"
                   (bashrc-preamble)
                   (bashrc-shared-library)
                   (bashrc-library-data)
                   (bashrc-postlude)))

(define wolk-jjba-fancy-bash-service
  (simple-service 'wolk-jjba-fancy-bash home-bash-service-type
                  (home-bash-extension (environment-variables '())
                                       (bashrc `(,wolk-jjba-bashrc)))))

(define wolk-jjba-home-vars-service
  (simple-service 'some-useful-env-vars-service
                  home-environment-variables-service-type
                  `(("SBCL_HOME" . "$HOME/.guix-home/profile/lib/sbcl")
                    ("GUIX_LOCPATH" . "$HOME/.guix-profile/lib/locale")
                    ("LANG" . "nl_NL.UTF-8")
                    ("LANGUAGE" . "nl_NL"))))

(display "\n>>= configuring home environment...\n")
(home-environment
  (services
   (append (list wolk-jjba-home-files-service wolk-jjba-home-vars-service
                 wolk-jjba-fancy-bash-service) %base-home-services)))
