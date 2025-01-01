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

(load "./nginx.scm")

(use-modules (gnu)
             (guix)
             (guix packages)
             (gnu packages package-management)
             ((guix licenses)
              #:prefix license:)
             (guix build-system gnu))

(use-modules (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 time)
             (ice-9 format)
             (ice-9 string-fun)
             (ice-9 iconv)
             (ice-9 threads)
             (wolk-jjba-nginx))

(use-package-modules base
                     idutils
                     certs
                     guile-xyz
                     guile
                     bash
                     nss
                     pkg-config
                     admin
                     emacs
                     ssh
                     glib
                     ncurses
                     node
                     screen
                     version-control
                     shellutils
                     databases
                     docker
                     gcc
                     python
                     multiprecision
                     ssh
                     guile-xyz
                     compression
                     rust-apps
                     terminals
                     avahi
                     linux
                     vim
                     sqlite
                     curl
                     disk
                     package-management)

(use-service-modules networking
                     desktop
                     docker
                     ssh
                     avahi
                     nix
                     web
                     certbot
                     dbus
                     shepherd
                     mcron)

(define wolk-jjba-filesystems
  (list (file-system
          (device (uuid "05c98e2c-cdfd-4b41-8719-e82354529d8a"))
          (mount-point "/")
          (type "ext4"))))

(define-public sss-artanis
  (package
   (name "artanis")
   (version "1.0.0")
   (source
    (origin
     (method url-fetch)
     (uri (string-append "mirror://gnu/artanis/artanis-" version ".tar.gz"))
     (sha256
      (base32 "05sigqvm04x0r1gwpwrxjffb3i13bss3ff24frr477zqm54wv5d8"))
     (modules '((guix build utils)))
     (snippet '(begin
                 (substitute* '("artanis/artanis.scm" "artanis/lpc.scm"
                                "artanis/oht.scm" "artanis/tpl/parser.scm")
                              (("(#:use-module \\()artanis third-party (json\\))" _
                                use-module json)
                               (string-append use-module json)))
                 (substitute* '("artanis/lpc.scm" "artanis/session.scm")
                              (("(#:use-module \\()artanis third-party (redis\\))" _
                                use-module redis)
                               (string-append use-module redis)))
                 (substitute* "artanis/oht.scm"
                              (("([[:punct:][:space:]]+)(->json-string)([[:punct:][:space:]]+)"
                                _ pre json-string post)
                               (string-append pre "scm" json-string post)))
                 (substitute* "artanis/artanis.scm"
                              (("[[:punct:][:space:]]+->json-string[[:punct:][:space:]]+")
                               "")) #t))))
   (build-system gnu-build-system)
   (inputs (list bash-minimal guile-3.0 nspr nss))
   ;; FIXME the bundled csv contains one more exported procedure
   ;; (sxml->csv-string) than guile-csv. The author is maintainer of both
   ;; projects.
   ;; TODO: Add guile-dbi and guile-dbd optional dependencies.
   (propagated-inputs (list guile-json-4 guile-curl guile-readline
                            guile-redis))
   (native-inputs (list bash-minimal ;for the `source' builtin
                        pkg-config util-linux)) ;for the `script' command
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
             (effective-version (target-guile-effective-version (assoc-ref
                                                                 %build-inputs
                                                                 "guile")))
             (scm (string-append out "/share/guile/site/" effective-version))
             (go (string-append out "/lib/guile/" effective-version
                                "/site-ccache")))
        ;; Don't use (%site-dir) for site paths.
        (list (string-append "MOD_PATH=" scm)
              (string-append "MOD_COMPILED_PATH=" go)))
      #:test-target "test"
      #:phases (modify-phases %standard-phases
                              (add-after 'unpack 'patch-site-dir
                                         (lambda* (#:key outputs #:allow-other-keys)
                                           (substitute* "artanis/commands/help.scm"
                                                        (("\\(%site-dir\\)")
                                                         (string-append "\""
                                                                        (assoc-ref outputs "out")
                                                                        "/share/guile/site/"
                                                                        (target-guile-effective-version) "\"")))))
                              (add-after 'unpack 'patch-reference-to-libnss
                                         (lambda* (#:key inputs #:allow-other-keys)
                                           (substitute* "artanis/security/nss.scm"
                                                        (("ffi-binding \"libnss3\"")
                                                         (string-append "ffi-binding \""
                                                                        (assoc-ref inputs "nss")
                                                                        "/lib/nss/libnss3.so" "\""))
                                                        (("ffi-binding \"libssl3\"")
                                                         (string-append "ffi-binding \""
                                                                        (assoc-ref inputs "nss")
                                                                        "/lib/nss/libssl3.so\"")))))
                              (add-before 'install 'substitute-root-dir
                                          (lambda* (#:key outputs #:allow-other-keys)
                                            (let ((out (assoc-ref outputs "out")))
                                              (substitute* "Makefile"
                                        ;ignore the execution of bash.bashrc
                                                           ((" /etc/bash.bashrc")
                                                            " /dev/null"))
                                              (substitute* "Makefile"
                                        ;set the root of config files to OUT
                                                           ((" /etc")
                                                            (string-append " " out "/etc")))
                                              (mkdir-p (string-append out "/bin")))))
                              (add-after 'install 'wrap-art
                                         (lambda* (#:key inputs outputs #:allow-other-keys)
                                           (let* ((out (assoc-ref outputs "out"))
                                                  (effective-version (target-guile-effective-version))
                                                  (bin (string-append out "/bin"))
                                                  (scm (string-append out "/share/guile/site/"
                                                                      effective-version))
                                                  (go (string-append out "/lib/guile/"
                                                                     effective-version
                                                                     "/site-ccache")))
                                             (wrap-program (string-append bin "/art")
                                                           `("GUILE_LOAD_PATH" ":" prefix
                                                             (,scm ,(getenv "GUILE_LOAD_PATH")))
                                                           `("GUILE_LOAD_COMPILED_PATH" ":" prefix
                                                             (,go ,(getenv "GUILE_LOAD_COMPILED_PATH"))))))))))
   (synopsis "Web application framework written in Guile")
   (description
    "GNU Artanis is a web application framework written in Guile
Scheme.  A web application framework (WAF) is a software framework that is
designed to support the development of dynamic websites, web applications, web
services and web resources.  The framework aims to alleviate the overhead
associated with common activities performed in web development.  Artanis
provides several tools for web development: database access, templating
frameworks, session management, URL-remapping for RESTful, page caching, and
more.")
   (home-page "https://www.gnu.org/software/artanis/")
   (license (list license:gpl3+ license:lgpl3+))))
                                        ;dual license

(define-public sss-guile-dbi
  (package
   (name "guile-dbi")
   (version "2.1.8")
   (source
    (origin
     (method git-fetch)
     (uri (git-reference
           (url "https://github.com/opencog/guile-dbi")
           (commit (string-append "guile-dbi-" version))))
     (file-name (git-file-name name version))
     (sha256
      (base32 "123m4j82bi60s1v95pjh4djb7bh6zdwmljbpyg7zq8ni2gyal7lw"))))
   (build-system gnu-build-system)
   (arguments
    `(#:make-flags '("LDFLAGS=\"-Wl,-allow-multiple-definition\"")
      #:modules (((guix build guile-build-system)
                  #:select (target-guile-effective-version))
                 ,@%default-gnu-modules)
      #:imported-modules ((guix build guile-build-system)
                          ,@%default-gnu-imported-modules)
      #:configure-flags (list (string-append "--with-guile-site-dir=" %output
                                             "/share/guile/site/"
                                             (target-guile-effective-version (assoc-ref
                                                                              %build-inputs
                                                                              "guile"))))
      #:phases (modify-phases %standard-phases
                              (add-after 'unpack 'chdir
                                         (lambda _
                                           ;; The upstream Git repository contains all the code, so change
                                           ;; to the directory specific to guile-dbi.
                                           (chdir "guile-dbi")))
                              (add-after 'install 'patch-extension-path
                                         (lambda* (#:key inputs outputs #:allow-other-keys)
                                           (let* ((out (assoc-ref outputs "out"))
                                                  (dbi.scm (string-append out "/share/guile/site/"
                                                                          (target-guile-effective-version
                                                                           (assoc-ref inputs
                                                                                      "guile"))
                                                                          "/dbi/dbi.scm"))
                                                  (ext (string-append out "/lib/libguile-dbi")))
                                             (substitute* dbi.scm
                                                          (("libguile-dbi")
                                                           ext))))))))
   (native-inputs (list autoconf
                        automake
                        libtool
                        perl
                        texinfo
                        libltdl))
   (propagated-inputs (list guile-3.0))
   (synopsis "Guile database abstraction layer")
   (home-page "https://github.com/opencog/guile-dbi")
   (description
    "guile-dbi is a library for Guile that provides a convenient interface to
SQL databases.  Database programming with guile-dbi is generic in that the same
programming interface is presented regardless of which database system is used.
It currently supports MySQL, Postgres and SQLite3.")
   (license license:gpl2+)
   (native-search-paths
    (list (search-path-specification
           (variable "GUILE_DBD_PATH")
           (files '("lib")))))))

(define-public sss-guile-dbd-sqlite3
  (package
   (inherit sss-guile-dbi)
   (name "guile-dbd-sqlite3")
   (arguments
    (substitute-keyword-arguments (package-arguments sss-guile-dbi)
                                  ((#:phases phases)
                                   `(modify-phases ,phases
                                                   (replace 'chdir
                                                            (lambda _
                                                              ;; The upstream Git repository contains all the code, so change
                                                              ;; to the directory specific to guile-dbd-sqlite3.
                                                              (chdir "guile-dbd-sqlite3")))
                                                   (delete 'patch-extension-path)))))
   (inputs (list sqlite zlib))
   (native-inputs (modify-inputs (package-native-inputs sss-guile-dbi)
                                 (prepend sss-guile-dbi ;only required for headers
                                          pkg-config)))
   (synopsis "Guile DBI driver for SQLite")
   (description
    "guile-dbi is a library for Guile that provides a convenient interface to
SQL databases.  This package implements the interface for SQLite.")))


(define wolk-jjba-system-packages
  (list (specification->package "openjdk@21.0.2")
        htop
        emacs
        openssh
        dbus
        ncurses
        screen
        tar
        zip
        unzip
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
        sss-guile-dbi
        sss-guile-dbd-sqlite3
        sss-artanis))

(define wolk-jjba-joe-user-account
  (user-account
    (name "joe")
    (group "users")
    (supplementary-groups '("wheel" "netdev" "audio" "video" "docker" "input"))))

(define wolk-jjba-ssh-service
  (service openssh-service-type
           (openssh-configuration (openssh openssh-sans-x)
                                  (password-authentication? #f)
                                  (port-number 2323)
                                  (max-connections 23)
                                  (authorized-keys `(("joe" ,(local-file
                                                              "/home/joe/.ssh/wolk-jjba.pub")))))))

(define %nginx-deploy-hook
  (program-file "nginx-deploy-hook"
                #~(let ((pid (call-with-input-file "/var/run/nginx/pid"
                               read)))
                    (kill pid SIGHUP))))

(define wolk-jjba-jointhefreeworld-certbot-cert
  (certificate-configuration (domains '("jointhefreeworld.org"
                                        "www.jointhefreeworld.org"))
                             (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-carvoeirowaterfun-certbot-cert
  (certificate-configuration (domains '("carvoeirowaterfun.com"
                                        "www.carvoeirowaterfun.com"))
                             (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-casadelcata-certbot-cert
  (certificate-configuration (domains '("casadelcata.es" "www.casadelcata.es"))
                             (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-byggsteg-certbot-cert
  (certificate-configuration (domains '("byggsteg.jointhefreeworld.org"
                                        "www.byggsteg.jointhefreeworld.org"))
                             (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-wikimusic-ssr-certbot-cert
  (certificate-configuration (domains '("wikimusic.jointhefreeworld.org"
                                        "www.wikimusic.jointhefreeworld.org"))
                             (deploy-hook %nginx-deploy-hook)))

(define wolk-jjba-wikimusic-api-certbot-cert
  (certificate-configuration (domains '("api.wikimusic.jointhefreeworld.org"))
                             (deploy-hook %nginx-deploy-hook)))

;; You may want to use a staging ACME server when testing.
;; (define %certbot-server
;;   "https://acme-staging-v02.api.letsencrypt.org/directory")

(define (wolk-jjba-byggsteg-service config)
  (list (shepherd-service (documentation "Run byggsteg as a daemon")
                          (provision '(byggsteg))
                          (requirement '())
                          (start #~(make-forkexec-constructor '("make"
                                                                "server")
                                    #:directory
                                    "/var/log/byggsteg/job-clone/byggsteg/trunk"
                                    #:environment-variables (list
                                                             "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin"
                                                             "GIT_SSL_NO_VERIFY=1"
                                                             "LANG=nl_NL.UTF-8")))
                          (stop #~(make-kill-destructor))
                          (auto-start? #t)
                          (respawn? #t))))

(define wolk-jjba-byggsteg-service-type
  (service-type (name 'byggsteg)
                (description "Run byggsteg as a daemon")
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   wolk-jjba-byggsteg-service)))
                (default-value '())))

(define (wolk-jjba-wikimusic-ssr-service config)
  (list (shepherd-service (documentation "Run WikiMusic SSR as a daemon")
                          (provision '(wikimusic-ssr))
                          (requirement '())
                          (start #~(make-forkexec-constructor '("make"
                                                                "server")
                                    #:directory
                                    "/var/log/byggsteg/job-clone/wikimusic-ssr/trunk"
                                    #:environment-variables (list
                                                             "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin"
                                                             "GIT_SSL_NO_VERIFY=1"
                                                             "LANG=nl_NL.UTF-8")))
                          (stop #~(make-kill-destructor))
                          (auto-start? #t)
                          (respawn? #t))))

(define wolk-jjba-wikimusic-ssr-service-type
  (service-type (name 'wikimusic-ssr)
                (description "Run WikiMusic SSR as a daemon")
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   wolk-jjba-wikimusic-ssr-service)))
                (default-value '())))

(define (wolk-jjba-wikimusic-api-service config)
  (list (shepherd-service (documentation "Run wikimusic-api as a daemon")
                          (provision '(wikimusic-api))
                          (requirement '())
                          (start #~(make-forkexec-constructor '("make"
                                                                "server")
                                    #:directory
                                    "/var/log/byggsteg/job-clone/wikimusic-api/trunk"
                                    #:environment-variables (list
                                                             "PATH=/run/privileged/bin:/run/current-system/profile/bin:/run/current-system/profile/sbin:/home/joe/.nix-profile/bin"
                                                             "GIT_SSL_NO_VERIFY=1"
                                                             "LANG=nl_NL.UTF-8")))
                          (stop #~(make-kill-destructor))
                          (auto-start? #t)
                          (respawn? #t))))

(define wolk-jjba-wikimusic-api-service-type
  (service-type (name 'wikimusic-api)
                (description "Run wikimusic-api as a daemon")
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   wolk-jjba-wikimusic-api-service)))
                (default-value '())))

(define (syscall cmd)
  (let* ((process (open-input-pipe cmd))
         (process-output (get-string-all process)))
    (close-pipe process)
    (display process-output) process-output))

(define (wikimusic-make-backups)
  (syscall
   "cd /srv/wikimusic && tar -czvf \"./backups/wikimusic-$(date +%s).tar.gz\" db.sqlite"))

(define wikimusic-make-backups-job
  #~(job '(next-hour '(2 4
                       6
                       8
                       10
                       12
                       14
                       16
                       18
                       20))
         (lambda ()
           (wikimusic-make-backups)) "wikimusic-make-backups"))

(define wolk-jjba-cron-jobs-service
  (simple-service 'wolk-jjba-cron-jobs mcron-service-type
                  (list wikimusic-make-backups-job)))

(define (nix-profile-install x)
  (syscall (format #f
            "nix -L --extra-experimental-features 'nix-command flakes' profile install --impure nixpkgs#~a"
            x)))

;;
;;
;; start run
;;

(display "\n>>= installing nix packages\n")
(for-each (lambda (x)
            (nix-profile-install x))
          '("stack" "sbt"))

(operating-system
 (host-name "wolk-jjba")
 (timezone "Europe/Amsterdam")

 ;; (locale "en_US.utf8")
 (locale "nl_NL.utf8")
 (keyboard-layout (keyboard-layout "us"))

 (bootloader (bootloader-configuration
              (bootloader grub-bootloader)
              (targets '("/dev/sda"))))

 (kernel-arguments (list "console=ttyS0,115200"))
 (sudoers-file (local-file "system/sudoers"))
 (initrd-modules (append (list "virtio_scsi") %base-initrd-modules))
 (file-systems (append wolk-jjba-filesystems %base-file-systems))

 (users (cons* wolk-jjba-joe-user-account %base-user-accounts))

 (packages (append wolk-jjba-system-packages %base-packages))

 (services
  (cons* (service dbus-root-service-type)
         (service avahi-service-type)
         (service udisks-service-type)
         (service upower-service-type)
         (service accountsservice-service-type)
         (service openntpd-service-type
                  (openntpd-configuration (listen-on '("127.0.0.1" "::1"))
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
                  (certbot-configuration (email "jjbigorra@gmail.com")
                                         (webroot "/srv/http")
                                         (certificates (list
                                                        wolk-jjba-casadelcata-certbot-cert
                                                        wolk-jjba-carvoeirowaterfun-certbot-cert
                                                        wolk-jjba-wikimusic-api-certbot-cert
                                                        wolk-jjba-byggsteg-certbot-cert
                                                        wolk-jjba-wikimusic-ssr-certbot-cert
                                                        wolk-jjba-jointhefreeworld-certbot-cert))))

         (service nginx-service-type
                  (nginx-configuration (server-blocks (list
                                                       wolk-jjba-base-nginx-conf
                                                       wolk-jjba-jointhefreeworld-nginx-conf
                                                       wolk-jjba-carvoeirowaterfun-nginx-conf
                                                       wolk-jjba-casadelcata-nginx-conf
                                                       wolk-jjba-byggsteg-nginx-conf
                                                       wolk-jjba-wikimusic-api-nginx-conf
                                                       wolk-jjba-wikimusic-ssr-nginx-conf))
                                       (upstream-blocks (list (nginx-upstream-configuration
                                                               (name
                                                                "byggsteg-proxy")
                                                               (servers (list
                                                                         "127.0.0.1:50002")))
                                                              (nginx-upstream-configuration
                                                               (name
                                                                "wikimusic-api-proxy")
                                                               (servers (list
                                                                         "127.0.0.1:50050")))
                                                              (nginx-upstream-configuration
                                                               (name
                                                                "wikimusic-ssr-proxy")
                                                               (servers (list
                                                                         "127.0.0.1:6923")))))))
         (service wolk-jjba-byggsteg-service-type)
         (service wolk-jjba-wikimusic-ssr-service-type)
         (service wolk-jjba-wikimusic-api-service-type)
         wolk-jjba-cron-jobs-service
         %base-services)))

