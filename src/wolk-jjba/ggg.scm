;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; The ggg badge server.  ggg is a released package rather than one of
;; the Byggsteg checkouts: `ggg --serve' answers GET /badge.svg from the
;; URL query string, reads the logo library from its own store item and
;; writes nothing, so the Shepherd can run it straight from the store.
;;
;; The package is pinned here instead of taken from Guix because Guix's
;; ggg is 0.4.16 and predates --serve.  Keep the pin in step with ggg's
;; releases; the hash is the tree of the tag, not of a generated tarball.
;;
;; The daemon binds loopback only.  nginx serves ggg.jointhefreeworld.org
;; from the ggg-proxy upstream in (wolk-jjba nginx), so this service and
;; that vhost are one pairing: the daemon holds the port, nginx holds the
;; certificate and the name.
;;
;;; Code:

(define-module (wolk-jjba ggg)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix build-system guile)
  #:use-module (guix build utils)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages base)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages imagemagick)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (ice-9 match)
  #:export (ggg-package
            ggg-server-port
            wolk-jjba-ggg-server-service
            wolk-jjba-ggg-server-service-type))

(define-public ggg-package
  (package
    (name "ggg")
    (version "0.17.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/jjba23/ggg")
             (commit "88d72244a53317bdde9e9579e28b0695f14fe146")))
       (file-name (git-file-name name version))
       (sha256
        (base32 "1j708wcsa6p4cl9kj7hxx9m9dkd166kwf38kbkz6d8csih04kkcd"))))
    (build-system guile-build-system)
    (arguments
     (list
      #:source-directory "src"
      #:modules '((guix build guile-build-system)
                  (guix build utils)
                  (ice-9 match))
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'build 'install-program-files
            (lambda _
              (let ((bin (string-append #$output "/bin"))
                    (share (string-append #$output "/share")))
                (install-file "resources/help.txt"
                              (string-append share "/ggg/resources"))
                (copy-recursively "resources/logos"
                                  (string-append share "/ggg/resources/logos"))
                (install-file "scripts/ggg" bin)
                (chmod (string-append bin "/ggg") #o755))))
          (add-after 'unpack 'fix-paths
            (lambda* (#:key inputs #:allow-other-keys)
              (for-each (match-lambda
                          ((pattern program format-string)
                           (substitute* "scripts/ggg"
                             ((pattern)
                              (format #f format-string
                                      (search-input-file inputs
                                                         (string-append "bin/"
                                                                        program)))))))
                        '(("readlink -f " "readlink" "~s -f ")
                          ("realpath " "realpath" "~s ")
                          ("dirname " "dirname" "~s ")
                          ("getopt " "getopt" "~s ")
                          ("exec guile " "guile" "exec ~s ")))
              (for-each (match-lambda
                          ((pattern program format-string)
                           (substitute* "src/ggg/main.scm"
                             ((pattern)
                              (format #f format-string
                                      (search-input-file inputs
                                                         (string-append "bin/"
                                                                        program)))))))
                        '(("\"convert\"" "convert" "~s"))))))))
    (inputs (list guile-3.0
                  bash-minimal
                  imagemagick
                  coreutils-minimal
                  util-linux))
    (synopsis "SVG image generator for project and web badges")
    (description
     "GGG (Guile Glyph Generator) generates SVG images for project and web
badges from Scheme descriptions.  Its --serve mode answers GET /badge.svg
with a badge described by the URL query string, so a README can link to a
live badge instead of a generated file.")
    (home-page "https://github.com/jjba23/ggg")
    (license license:expat)))

(define ggg-server-port
  50055)

(define* (wolk-jjba-ggg-server-service #:key (port ggg-server-port))
  "Return the Shepherd service that runs the ggg badge server on loopback.

The service is deliberately local-only: nginx serves
ggg.jointhefreeworld.org and proxies it here, so the port is never
reachable from the internet."
  (list (shepherd-service
         (documentation "Run the ggg badge server on 127.0.0.1.")
         (provision '(ggg-server))
         (requirement '(networking))
         (start #~(lambda args
                    (mkdir-p "/var/log/wolk-jjba")
                    ((make-forkexec-constructor
                      (list #$(file-append ggg-package "/bin/ggg")
                            "--serve"
                            "--host" "127.0.0.1"
                            "--port" #$(number->string port))
                      #:log-file "/var/log/wolk-jjba/ggg-server.log")
                     args)))
         (stop #~(make-kill-destructor))
         (auto-start? #t)
         (respawn? #t))))

(define wolk-jjba-ggg-server-service-type
  (service-type
   (name 'ggg-server)
   (description "Run the ggg badge server on loopback.")
   (default-value '())
   (extensions
    (list (service-extension shepherd-root-service-type
                              (lambda (config)
                                (wolk-jjba-ggg-server-service)))))))
