;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Packages for the native observability stack: Prometheus, Loki,
;; Grafana, Grafana Alloy and Tempo.
;;
;; None of these are packaged in Guix 1.5.  Rather than run them in
;; containers, these definitions install the upstream Linux amd64
;; release artifacts, pinned by version and SHA-256, into the Guix
;; store.  The binaries are static Go programs (Alloy is the exception:
;; it is run through the Guix glibc loader by a small wrapper), so the
;; result behaves like any other Guix package: fixed inputs, no network
;; at build time, no Docker or Podman.
;;
;; Update a package by bumping VERSION and running `guix hash' on the
;; new release artifact.
;;
;; Code:

(define-module (wolk-jjba monitoring-packages)
  #:use-module (guix)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system copy)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages compression)
  #:export (prometheus loki grafana alloy tempo))

(define-public prometheus
  (package
    (name "prometheus")
    (version "3.15.0")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/prometheus/prometheus/releases/download/v"
             version "/prometheus-" version ".linux-amd64.tar.gz"))
       (sha256
        (base32 "181fayfjx1mslfl9nmvnakxdl06yl4mgni6qp4byw0mc5vrjsm1a"))))
    (build-system copy-build-system)
    (arguments
     (list #:strip-binaries? #f
           #:install-plan
           #~'(("prometheus" "bin/prometheus")
               ("promtool" "bin/promtool")
               ("prometheus.yml" "share/prometheus/prometheus.yml")
               ("LICENSE" "share/doc/prometheus/LICENSE")
               ("NOTICE" "share/doc/prometheus/NOTICE"))))
    (home-page "https://prometheus.io/")
    (synopsis "Monitoring system and time series database")
    (description
     "Prometheus is a monitoring system and time series database.  This
package installs the upstream static Linux amd64 release, pinned by
version and hash, because Guix does not currently package the Prometheus
server.")
    (license license:asl2.0)))

(define-public loki
  (package
    (name "loki")
    (version "3.7.8")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/grafana/loki/releases/download/v"
             version "/loki-linux-amd64.zip"))
       (sha256
        (base32 "0qbx5y0qvk6whmzb0l5b4i6cx80rf2rnlrmk88bcslmskhna9bk2"))))
    (build-system copy-build-system)
    (native-inputs (list unzip))
    (arguments
     (list #:strip-binaries? #f
           #:install-plan #~'(("loki-linux-amd64" "bin/loki"))))
    (home-page "https://grafana.com/oss/loki/")
    (synopsis "Log aggregation system")
    (description
     "Loki is a horizontally scalable, highly available, multi-tenant
log aggregation system.  This package installs the upstream static Linux
amd64 release, pinned by version and hash.")
    (license license:agpl3)))

(define-public grafana
  (package
    (name "grafana")
    (version "13.2.4")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://dl.grafana.com/oss/release/grafana-"
             version ".linux-amd64.tar.gz"))
       (sha256
        (base32 "1awjgdcg79k7rzrx0q73nd5fda7q38jp19jfgrh751fqiyc6b1y4"))))
    (build-system copy-build-system)
    (arguments
     (list #:strip-binaries? #f
           #:install-plan
           #~'(("bin/grafana" "bin/grafana")
               ("conf/" "share/grafana/conf")
               ("public/" "share/grafana/public")
               ("plugins-bundled" "share/grafana/plugins-bundled")
               ("VERSION" "share/grafana/VERSION")
               ("LICENSE" "share/doc/grafana/LICENSE")
               ("NOTICE.md" "share/doc/grafana/NOTICE.md"))))
    (home-page "https://grafana.com/")
    (synopsis "Dashboard and visualization platform")
    (description
     "Grafana is a dashboard and visualization platform for time series
data.  This package installs the upstream static Linux amd64 release,
pinned by version and hash, together with its public assets and default
configuration.")
    (license license:agpl3)))

(define-public alloy
  (package
    (name "alloy")
    (version "1.21.0")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/grafana/alloy/releases/download/v"
             version "/alloy-linux-amd64.zip"))
       (sha256
        (base32 "1cxs9kmm7db6krj4jhcnmwgw863n6hlald9iqdjxi7dh58sc4j13"))))
    (build-system copy-build-system)
    (native-inputs (list unzip))
    (inputs (list bash-minimal glibc))
    (arguments
     (list #:strip-binaries? #f
           #:validate-runpath? #f
           #:install-plan #~'(("alloy-linux-amd64" "libexec/alloy"))
           #:phases
           #~(modify-phases %standard-phases
               (add-after 'install 'wrap
                 (lambda* (#:key inputs outputs #:allow-other-keys)
                   (let* ((out (assoc-ref outputs "out"))
                          (bash (assoc-ref inputs "bash-minimal"))
                          (glibc (assoc-ref inputs "glibc"))
                          (wrapper (string-append out "/bin/alloy")))
                     (mkdir-p (dirname wrapper))
                     (call-with-output-file wrapper
                       (lambda (port)
                         (format port
                                 "#!~a/bin/bash~%exec ~a/lib/ld-linux-x86-64.so.2 ~a/libexec/alloy \"$@\"~%"
                                 bash glibc out)))
                     (chmod wrapper #o755)))))))
    (home-page "https://grafana.com/oss/alloy/")
    (synopsis "OpenTelemetry collector and log shipper")
    (description
     "Grafana Alloy is an OpenTelemetry collector with a configuration
language derived from River.  wolk-jjba uses it to tail host log files
and push them to Loki.  This package installs the upstream Linux amd64
release and wraps it with the Guix glibc loader.")
    (license license:asl2.0)))

(define-public tempo
  (package
    (name "tempo")
    (version "3.1.0")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/grafana/tempo/releases/download/v"
             version "/tempo_" version "_linux_amd64.tar.gz"))
       (sha256
        (base32 "0kmcnzf8z60vyyyqdy4faqb5wcv5rn8vl6w0ahls8w426i3an14n"))))
    (build-system copy-build-system)
    (arguments
     (list #:strip-binaries? #f
           #:install-plan
           #~'(("tempo" "bin/tempo")
               ("tempo-cli" "bin/tempo-cli")
               ("LICENSE" "share/doc/tempo/LICENSE")
               ("README.md" "share/doc/tempo/README.md"))))
    (home-page "https://grafana.com/oss/tempo/")
    (synopsis "Distributed tracing backend")
    (description
     "Grafana Tempo is a distributed tracing backend that stores traces in
object storage and accepts them over OTLP, Jaeger, Zipkin and OpenCensus.
wolk-jjba runs the single binary with local storage as the trace store for
the OpenTelemetry pipeline.  This package installs the upstream static
Linux amd64 release, pinned by version and hash.")
    (license license:agpl3)))
