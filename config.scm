;;;; config.scm

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


(use-modules (gnu)
             (guix packages)
             (gnu services networking)
             (gnu packages admin)
             (gnu packages emacs)
             (gnu packages ssh)
             (gnu packages glib)
             (gnu packages ncurses)
             (gnu packages node)
             (gnu packages screen)
             (gnu packages version-control)
             (gnu packages shellutils)
             (gnu packages databases)
             (gnu packages docker)
             (gnu packages gcc)
             (gnu packages python)
             (gnu services nix)
             (gnu packages multiprecision)
             (gnu packages ssh)
             (gnu packages guile-xyz)
             (gnu packages compression)
             (gnu packages rust-apps)
             (gnu packages terminals)
             (gnu packages avahi)
             (gnu services avahi)
             (gnu packages guile)
             (gnu packages linux)
             (gnu packages vim)
             (gnu packages sqlite)
             (gnu packages curl)
             (gnu packages disk)
             (gnu services web)
             (gnu services certbot)
             (gnu packages package-management)
             ((guix licenses) #:prefix license:)
             (gnu services dbus)
             (guix build-system gnu)
             (gnu services shepherd))

(use-modules (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 time)
             (ice-9 format)
             (ice-9 string-fun)
             (ice-9 iconv)
             (ice-9 threads))
(use-modules (guix) (gnu) (gnu services mcron))
(use-package-modules base idutils)

(use-service-modules networking desktop docker ssh)
(use-package-modules certs guile-xyz guile bash nss pkg-config)

(define wolk-jjba-filesystems
  (list   
   (file-system
    (device (uuid "05c98e2c-cdfd-4b41-8719-e82354529d8a"))
    (mount-point "/")
    (type "ext4"))))

(define-public sss-artanis
  (package
   (name "artanis")
   (version "1.0.0")
   (source (origin
            (method url-fetch)
            ;;(uri (string-append "https://ftp.gnu.org/gnu/artanis/artanis-1.0.0.tar.gz"))
            (uri (string-append "mirror://gnu/artanis/artanis-"
                                version ".tar.gz"))
            (sha256
             (base32
              "05sigqvm04x0r1gwpwrxjffb3i13bss3ff24frr477zqm54wv5d8"))
            (modules '((guix build utils)))
            (snippet
             '(begin
                ;; Unbundle guile-redis and guile-json
                ;; (delete-file-recursively "artanis/third-party/json.scm")
                ;; (delete-file-recursively "artanis/third-party/json")
                ;; (delete-file-recursively "artanis/third-party/redis.scm")
                ;; (delete-file-recursively "artanis/third-party/redis")
                (substitute* '("artanis/artanis.scm"
                               "artanis/lpc.scm"
                               "artanis/oht.scm"
                               "artanis/tpl/parser.scm")
                             (("(#:use-module \\()artanis third-party (json\\))" _
                               use-module json)
                              (string-append use-module json)))
                (substitute* '("artanis/lpc.scm"
                               "artanis/session.scm")
                             (("(#:use-module \\()artanis third-party (redis\\))" _
                               use-module redis)
                              (string-append use-module redis)))
                (substitute* "artanis/oht.scm"
                             (("([[:punct:][:space:]]+)(->json-string)([[:punct:][:space:]]+)"
                               _ pre json-string post)
                              (string-append pre
                                             "scm" json-string
                                             post)))
                (substitute* "artanis/artanis.scm"
                             (("[[:punct:][:space:]]+->json-string[[:punct:][:space:]]+")
                              ""))
                #t))))
   (build-system gnu-build-system)
   ;; guile-3.0.9
   ;; guile-dbi-2.1.8
   ;; guile-dbd-mysql-2.1.8
   ;; guile-curl-0.9
   ;; guile-redis-2.2.0
   ;; guile-json-4.7.3
   (inputs
    (list bash-minimal guile-3.0 nspr nss))
   ;; FIXME the bundled csv contains one more exported procedure
   ;; (sxml->csv-string) than guile-csv. The author is maintainer of both
   ;; projects.
   ;; TODO: Add guile-dbi and guile-dbd optional dependencies.
   (propagated-inputs
    (list guile-json-4 guile-curl guile-readline guile-redis))
   (native-inputs
    (list bash-minimal                           ;for the `source' builtin
          pkg-config
          util-linux))                           ;for the `script' command
   (arguments
    `(#:modules (((guix build guile-build-system)
                  #:select (target-guile-effective-version))
                 ,@%default-gnu-modules)
      #:imported-modules ((guix build guile-build-system)
                          ,@%default-gnu-imported-modules)
      #:make-flags
      ;; TODO: The documentation must be built with the `docs' target.
      (let* ((out (assoc-ref %outputs "out"))
             ;; We pass guile explicitly here since this executes before the
             ;; set-paths phase and therefore guile is not yet in PATH.
             (effective-version (target-guile-effective-version
                                 (assoc-ref %build-inputs "guile")))
             (scm (string-append out "/share/guile/site/" effective-version))
             (go (string-append out "/lib/guile/" effective-version "/site-ccache")))
        ;; Don't use (%site-dir) for site paths.
        (list (string-append "MOD_PATH=" scm)
              (string-append "MOD_COMPILED_PATH=" go)))
      #:test-target "test"
      #:phases
      (modify-phases %standard-phases
                     (add-after 'unpack 'patch-site-dir
                                (lambda* (#:key outputs #:allow-other-keys)
                                  (substitute* "artanis/commands/help.scm"
                                               (("\\(%site-dir\\)")
                                                (string-append "\""
                                                               (assoc-ref outputs "out")
                                                               "/share/guile/site/"
                                                               (target-guile-effective-version)
                                                               "\"")))))
                     (add-after 'unpack 'patch-reference-to-libnss
                                (lambda* (#:key inputs #:allow-other-keys)
                                  (substitute* "artanis/security/nss.scm"
                                               (("ffi-binding \"libnss3\"")
                                                (string-append
                                                 "ffi-binding \""
                                                 (assoc-ref inputs "nss") "/lib/nss/libnss3.so"
                                                 "\""))
                                               (("ffi-binding \"libssl3\"")
                                                (string-append
                                                 "ffi-binding \"" (assoc-ref inputs "nss") "/lib/nss/libssl3.so\"")))))
                     (add-before 'install 'substitute-root-dir
                                 (lambda* (#:key outputs #:allow-other-keys)
                                   (let ((out  (assoc-ref outputs "out")))
                                     (substitute* "Makefile"   ;ignore the execution of bash.bashrc
                                                  ((" /etc/bash.bashrc") " /dev/null"))
                                     (substitute* "Makefile"   ;set the root of config files to OUT
                                                  ((" /etc") (string-append " " out "/etc")))
                                     (mkdir-p (string-append out "/bin")) )))
                     (add-after 'install 'wrap-art
                                (lambda* (#:key inputs outputs #:allow-other-keys)
                                  (let* ((out (assoc-ref outputs "out"))
                                         (effective-version (target-guile-effective-version))
                                         (bin (string-append out "/bin"))
                                         (scm (string-append out "/share/guile/site/" effective-version))
                                         (go (string-append out "/lib/guile/" effective-version
                                                            "/site-ccache")))
                                    (wrap-program (string-append bin "/art")
                                                  `("GUILE_LOAD_PATH" ":" prefix
                                                    (,scm ,(getenv "GUILE_LOAD_PATH")))
                                                  `("GUILE_LOAD_COMPILED_PATH" ":" prefix
                                                    (,go ,(getenv "GUILE_LOAD_COMPILED_PATH"))))))))))
   (synopsis "Web application framework written in Guile")
   (description "GNU Artanis is a web application framework written in Guile
Scheme.  A web application framework (WAF) is a software framework that is
designed to support the development of dynamic websites, web applications, web
services and web resources.  The framework aims to alleviate the overhead
associated with common activities performed in web development.  Artanis
provides several tools for web development: database access, templating
frameworks, session management, URL-remapping for RESTful, page caching, and
more.")
   (home-page "https://www.gnu.org/software/artanis/")
   (license (list license:gpl3+ license:lgpl3+)))) ;dual license



(define wolk-jjba-system-packages
  (list
   (specification->package "openjdk@21.0.2")
   htop
   emacs
   openssh
   dbus
   ncurses
   screen
   tar
   zip unzip
   gmp
   gcc
   (specification->package "guile")
   guile-fibers
   kitty
   xxd
   curl
   git
   ripgrep
   net-tools
   dstat
   sqlite
   python
   (specification->package "node@18.19.0")
   fzf
   (specification->package "make")
   nix
   coreutils
   sss-artanis
   ))

(define wolk-jjba-joe-user-account
  (user-account
   (name "joe")
   (group "users")
   (supplementary-groups '("wheel" "netdev" "audio" "video" "docker" "input"))))

(define wolk-jjba-ssh-service
  (service openssh-service-type
           (openssh-configuration
            (openssh openssh-sans-x)
            (password-authentication? #false)
            (port-number 2323)
            (max-connections 23)
            (authorized-keys
             `(("joe" ,(local-file "/home/joe/.ssh/wolk-jjba.pub")))))))

(define %nginx-deploy-hook
  (program-file
   "nginx-deploy-hook"
   #~(let ((pid (call-with-input-file "/var/run/nginx/pid" read)))
       (kill pid SIGHUP))))

(define wolk-jjba-base-nginx-conf
  (nginx-server-configuration
   (listen '("80"))
   (server-name '("jointhefreeworld.org" "www.jointhefreeworld.org"
                  "casadelcata.es" "www.casadelcata.es"
                  "carvoeirowaterfun.com" "www.carvoeirowaterfun.com"
                  "byggsteg.jointhefreeworld.org" "www.byggsteg.jointhefreeworld.org"
                  "wikimusic.jointhefreeworld.org" "www.wikimusic.jointhefreeworld.org"
                  "api.wikimusic.jointhefreeworld.org"))
   (root "/srv/http")))

(define wolk-jjba-jointhefreeworld-nginx-conf
  (nginx-server-configuration
   (listen '("443 ssl"))
   (server-name '("jointhefreeworld.org" "www.jointhefreeworld.org"))
   (ssl-certificate "/etc/letsencrypt/live/jointhefreeworld.org/fullchain.pem")
   (ssl-certificate-key "/etc/letsencrypt/live/jointhefreeworld.org/privkey.pem")
   (root "/srv/http/jointhefreeworld.org")))

(define wolk-jjba-jointhefreeworld-certbot-cert
  (certificate-configuration
   (domains '("jointhefreeworld.org" "www.jointhefreeworld.org"))
   (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-carvoeirowaterfun-nginx-conf
  (nginx-server-configuration
   (listen '("443 ssl"))
   (server-name '("carvoeirowaterfun.com" "www.carvoeirowaterfun.com"))
   (ssl-certificate "/etc/letsencrypt/live/carvoeirowaterfun.com/fullchain.pem")
   (ssl-certificate-key "/etc/letsencrypt/live/carvoeirowaterfun.com/privkey.pem")
   (root "/srv/http/carvoeirowaterfun.com")))

(define wolk-jjba-carvoeirowaterfun-certbot-cert
  (certificate-configuration
   (domains '("carvoeirowaterfun.com" "www.carvoeirowaterfun.com"))
   (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-casadelcata-nginx-conf
  (nginx-server-configuration
   (listen '("443 ssl"))
   (server-name '("casadelcata.es" "www.casadelcata.es"))
   (ssl-certificate "/etc/letsencrypt/live/casadelcata.es/fullchain.pem")
   (ssl-certificate-key "/etc/letsencrypt/live/casadelcata.es/privkey.pem")
   (root "/srv/http/casadelcata.es")))

(define wolk-jjba-casadelcata-certbot-cert
  (certificate-configuration
   (domains '("casadelcata.es" "www.casadelcata.es"))
   (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-byggsteg-nginx-conf
  (nginx-server-configuration
   (listen '("443 ssl"))
   (server-name '("byggsteg.jointhefreeworld.org" "www.byggsteg.jointhefreeworld.org"))
   (ssl-certificate "/etc/letsencrypt/live/byggsteg.jointhefreeworld.org/fullchain.pem")
   (ssl-certificate-key "/etc/letsencrypt/live/byggsteg.jointhefreeworld.org/privkey.pem")
   (root "/srv/http")
   (locations
    (list
     (nginx-location-configuration
      (uri "/")
      (body '("proxy_pass http://byggsteg-proxy;")))
     ))))

(define wolk-jjba-byggsteg-certbot-cert
  (certificate-configuration
   (domains '("byggsteg.jointhefreeworld.org" "www.byggsteg.jointhefreeworld.org"))
   (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-wikimusic-ssr-nginx-conf
  (nginx-server-configuration
   (listen '("443 ssl"))
   (server-name '("wikimusic.jointhefreeworld.org" "www.wikimusic.jointhefreeworld.org"))
   (ssl-certificate "/etc/letsencrypt/live/wikimusic.jointhefreeworld.org/fullchain.pem")
   (ssl-certificate-key "/etc/letsencrypt/live/wikimusic.jointhefreeworld.org/privkey.pem")
   (root "/srv/http")
   (locations
    (list
     (nginx-location-configuration
      (uri "/")
      (body '("proxy_pass http://wikimusic-ssr-proxy;")))
     ))))

(define wolk-jjba-wikimusic-ssr-certbot-cert
  (certificate-configuration
   (domains '("wikimusic.jointhefreeworld.org" "www.wikimusic.jointhefreeworld.org"))
   (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-wikimusic-api-nginx-conf
  (nginx-server-configuration
   (listen '("443 ssl"))
   (server-name '("api.wikimusic.jointhefreeworld.org"))
   (ssl-certificate "/etc/letsencrypt/live/api.wikimusic.jointhefreeworld.org/fullchain.pem")
   (ssl-certificate-key "/etc/letsencrypt/live/api.wikimusic.jointhefreeworld.org/privkey.pem")
   (root "/srv/http")
   (locations
    (list
     (nginx-location-configuration
      (uri "/")
      (body '("proxy_pass http://wikimusic-api-proxy;")))
     ))))

(define wolk-jjba-wikimusic-api-certbot-cert
  (certificate-configuration
   (domains '("api.wikimusic.jointhefreeworld.org" ))
   (deploy-hook %nginx-deploy-hook)))

;; You may want to use a staging ACME server when testing.
;; (define %certbot-server
;;   "https://acme-staging-v02.api.letsencrypt.org/directory")

(define (wolk-jjba-byggsteg-service config)
  (list
   (shepherd-service
    (documentation "Run byggsteg as a daemon")
    (provision '(byggsteg))
    (requirement '())
    (start #~(make-forkexec-constructor
              '("make" "server")
              #:directory "/var/log/byggsteg/job-clone/byggsteg/trunk"
              #:environment-variables
              (list
               "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin"
               "GIT_SSL_NO_VERIFY=1"
               "LANG=nl_NL.UTF-8")))
    (stop #~(make-kill-destructor))
    (auto-start? #t)
    (respawn? #t)
    )))

(define wolk-jjba-byggsteg-service-type
  (service-type
   (name 'byggsteg)
   (description "Run byggsteg as a daemon")
   (extensions
    (list (service-extension
           shepherd-root-service-type
           wolk-jjba-byggsteg-service)))
   (default-value '())
   ))

(define (wolk-jjba-wikimusic-ssr-service config)
  (list
   (shepherd-service
    (documentation "Run WikiMusic SSR as a daemon")
    (provision '(wikimusic-ssr))
    (requirement '())
    (start #~(make-forkexec-constructor
              '("make" "server")
              #:directory "/var/log/byggsteg/job-clone/wikimusic-ssr/trunk"
              #:environment-variables
              (list
               "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin"
               "GIT_SSL_NO_VERIFY=1"
               "LANG=nl_NL.UTF-8")))
    (stop #~(make-kill-destructor))
    (auto-start? #t)
    (respawn? #t)
    )))

(define wolk-jjba-wikimusic-ssr-service-type
  (service-type
   (name 'wikimusic-ssr)
   (description "Run WikiMusic SSR as a daemon")
   (extensions
    (list (service-extension
           shepherd-root-service-type
           wolk-jjba-wikimusic-ssr-service)))
   (default-value '())
   ))

(define (wolk-jjba-wikimusic-api-service config)
  (list
   (shepherd-service
    (documentation "Run wikimusic-api as a daemon")
    (provision '(wikimusic-api))
    (requirement '())
    (start #~(make-forkexec-constructor
              '("make" "server")
              #:directory "/var/log/byggsteg/job-clone/wikimusic-api/trunk"
              #:environment-variables
              (list
               "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin"
               "GIT_SSL_NO_VERIFY=1"
               "LANG=nl_NL.UTF-8")))
    (stop #~(make-kill-destructor))
    (auto-start? #t)
    (respawn? #t)
    )))

(define wolk-jjba-wikimusic-api-service-type
  (service-type
   (name 'wikimusic-api)
   (description "Run wikimusic-api as a daemon")
   (extensions
    (list (service-extension
           shepherd-root-service-type
           wolk-jjba-wikimusic-api-service)))
   (default-value '())
   ))

(define (syscall cmd)
  (let* ((process (open-input-pipe cmd))
         (process-output (get-string-all process)))
    (close-pipe process)
    (display process-output)
    process-output))


(define (wikimusic-make-backups)
  (syscall "cd /srv/wikimusic && tar -czvf \"./backups/wikimusic-$(date +%s).tar.gz\" db.sqlite"))

(define wikimusic-make-backups-job
  #~(job '(next-hour '(2 4 6 8 10 12 14 16 18 20))
         (lambda ()
           (wikimusic-make-backups))
         "wikimusic-make-backups"
         ))


(define wolk-jjba-cron-jobs-service
  (simple-service 'wolk-jjba-cron-jobs
                  mcron-service-type
                  (list wikimusic-make-backups-job
                        )))


(define (nix-profile-install x)
  (syscall (format #f "nix -L --extra-experimental-features 'nix-command flakes' profile install --impure nixpkgs#~a" x)))

;;
;;
;; start run
;;

(display "\n>>= installing nix packages\n")
(for-each
 (lambda(x) (nix-profile-install x))
 '("stack"
   "sbt" ))

(operating-system
 (host-name "wolk-jjba")
 (timezone "Europe/Amsterdam")

 ;; (locale "en_US.utf8")
 (locale "nl_NL.utf8")
 (keyboard-layout (keyboard-layout "us"))

 (bootloader (bootloader-configuration
	      (bootloader grub-bootloader)
	      (targets '("/dev/sda"))))

 (kernel-arguments
  (list "console=ttyS0,115200"))
 (sudoers-file (local-file "system/sudoers"))
 (initrd-modules (append (list "virtio_scsi")
                         %base-initrd-modules)) 
 (file-systems
  (append
   wolk-jjba-filesystems
   %base-file-systems))
 
 (users
  (cons* wolk-jjba-joe-user-account
         %base-user-accounts))
 
 (packages
  (append wolk-jjba-system-packages
          %base-packages))
 
 (services
  (cons*
   (service dbus-root-service-type)
   (service avahi-service-type)
   (service udisks-service-type)
   (service upower-service-type)
   (service accountsservice-service-type)
   (service
    openntpd-service-type
    (openntpd-configuration
     (listen-on '("127.0.0.1" "::1"))
     (sensor '("udcf0 correction 70000"))
     (constraint-from '("www.gnu.org"))
     (constraints-from '("https://www.google.com/"))))
   wolk-jjba-ssh-service
   (service nix-service-type)
   (service elogind-service-type)
   (service network-manager-service-type)
   (service wpa-supplicant-service-type)
   (service modem-manager-service-type)
   (service containerd-service-type)
   (service docker-service-type)
   (service certbot-service-type
            (certbot-configuration
             (email "jjbigorra@gmail.com")
             (webroot "/srv/http")
             (certificates
              (list
               wolk-jjba-casadelcata-certbot-cert
               wolk-jjba-carvoeirowaterfun-certbot-cert
               wolk-jjba-wikimusic-api-certbot-cert
               wolk-jjba-byggsteg-certbot-cert
               wolk-jjba-wikimusic-ssr-certbot-cert
               wolk-jjba-jointhefreeworld-certbot-cert
               ))))
   
   (service
    nginx-service-type
    (nginx-configuration
     (server-blocks
      (list
       wolk-jjba-base-nginx-conf
       wolk-jjba-jointhefreeworld-nginx-conf
       wolk-jjba-carvoeirowaterfun-nginx-conf
       wolk-jjba-casadelcata-nginx-conf
       wolk-jjba-byggsteg-nginx-conf
       wolk-jjba-wikimusic-api-nginx-conf
       wolk-jjba-wikimusic-ssr-nginx-conf
       ))
     (upstream-blocks
      (list
       (nginx-upstream-configuration
        (name "byggsteg-proxy")
        (servers (list "127.0.0.1:3000")))
       (nginx-upstream-configuration
        (name "wikimusic-api-proxy")
        (servers (list "127.0.0.1:50050")))
       (nginx-upstream-configuration
        (name "wikimusic-ssr-proxy")
        (servers (list "127.0.0.1:6923")))
       ))))
   (service wolk-jjba-byggsteg-service-type)
   (service wolk-jjba-wikimusic-ssr-service-type)
   (service wolk-jjba-wikimusic-api-service-type)
   wolk-jjba-cron-jobs-service
   %base-services
   )))



