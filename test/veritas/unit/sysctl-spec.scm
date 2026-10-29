;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (wolk-jjba sysctl).  These settings are written once at
;; boot and a wrong key is silent: sysctl prints a warning and the machine
;; comes up without the protection.  So the tests name the settings that
;; are load-bearing for the firewall (SYN cookies, reverse-path filtering,
;; ICMP limits), check that every entry is a well-formed pair of strings,
;; and -- the one that would be an outage rather than a hole -- that
;; nothing here turns the host into a router or overrides the address
;; configuration NetworkManager owns.

;;; Code:

(define-module (veritas unit sysctl-spec)
  #:use-module (veritas veritas)
  #:use-module (gnu services sysctl)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba sysctl)
  #:export (spec))

(define settings wolk-jjba-sysctl-settings)

(define (value-of key)
  "Return the value SETTINGS gives KEY, or #f."
  (let ((entry (assoc key settings)))
    (and entry (cdr entry))))

(define settings-keys
  (map car settings))

(define sysctl-suite
  (suite "Sysctl Suite"

         (test "Every setting is a well-formed key/value pair"
               (assert-true (every (lambda (entry)
                                     (and (pair? entry)
                                          (string? (car entry))
                                          (string? (cdr entry))
                                          (not (string-null? (car entry)))
                                          (not (string-null? (cdr entry)))))
                                   settings)
                            #:name "Each entry is a dotted key and a string")
               (assert-equal #:expect (length settings-keys)
                             #:got (length (delete-duplicates settings-keys))
                             #:name "No key is set twice"))

         (test "The kernel survives a SYN flood"
               (assert-equal #:expect "1"
                             #:got (value-of "net.ipv4.tcp_syncookies")
                             #:name "Syncookies are on")
               (assert-true (and (string->number
                                  (or (value-of "net.ipv4.tcp_max_syn_backlog")
                                      "0"))
                                 (> (string->number
                                     (value-of "net.ipv4.tcp_max_syn_backlog"))
                                    1024))
                            #:name "The SYN backlog is larger than the default")
               (assert-true (and (string->number
                                  (or (value-of "net.core.somaxconn") "0"))
                                 (> (string->number
                                     (value-of "net.core.somaxconn"))
                                    512))
                            #:name "The accept queue is larger than the default"))

         (test "Spoofed and redirected traffic is not honoured"
               (assert-equal #:expect "1"
                             #:got (value-of "net.ipv4.conf.all.rp_filter")
                             #:name "Reverse-path filtering is strict")
               (assert-equal #:expect "1"
                             #:got (value-of "net.ipv4.conf.default.rp_filter")
                             #:name "and applies to interfaces created later")
               (assert-equal #:expect "0"
                             #:got (value-of "net.ipv4.conf.all.accept_redirects")
                             #:name "IPv4 redirects are refused")
               (assert-equal #:expect "0"
                             #:got (value-of "net.ipv6.conf.all.accept_redirects")
                             #:name "IPv6 redirects are refused")
               (assert-equal #:expect "0"
                             #:got (value-of "net.ipv4.conf.all.send_redirects")
                             #:name "This host sends no redirects")
               (assert-equal #:expect "0"
                             #:got (value-of "net.ipv4.conf.all.accept_source_route")
                             #:name "Source-routed IPv4 is refused"))

         (test "ICMP is bounded"
               (assert-equal #:expect "1"
                             #:got (value-of "net.ipv4.icmp_echo_ignore_broadcasts")
                             #:name "Broadcast echo is ignored")
               (assert-true (and (value-of "net.ipv4.icmp_ratelimit") #t)
                            #:name "Echo replies are rate limited"))

         (test "Kernel internals are not readable by ordinary users"
               (assert-equal #:expect "2"
                             #:got (value-of "kernel.kptr_restrict")
                             #:name "Kernel pointers are hidden")
               (assert-equal #:expect "1"
                             #:got (value-of "kernel.dmesg_restrict")
                             #:name "Only root reads the ring buffer")
               (assert-equal #:expect "1"
                             #:got (value-of "kernel.unprivileged_bpf_disabled")
                             #:name "Unprivileged BPF loading is off"))

         (test "The host keeps its routing and addressing role"
               (assert-false (member "net.ipv4.ip_forward" settings-keys)
                             #:name "Packet forwarding is left to Podman")
               (assert-false (member "net.ipv6.conf.all.forwarding" settings-keys)
                             #:name "IPv6 forwarding is left alone")
               (assert-false (member "net.ipv6.conf.all.accept_ra" settings-keys)
                             #:name "Router advertisements stay with NetworkManager")
               (assert-false (member "net.ipv6.conf.all.disable_ipv6" settings-keys)
                             #:name "IPv6 is not switched off"))

         (test "The settings extend Guix's defaults instead of replacing them"
               ;; config.scm extends the sysctl configuration that
               ;; %base-services already provides; a replacement would drop
               ;; fs.protected_hardlinks and fs.protected_symlinks.
               (let ((merged (extend-sysctl-configuration
                              (sysctl-configuration))))
                 (assert-true (and (assoc "fs.protected_hardlinks"
                                          (sysctl-configuration-settings merged))
                                   #t)
                              #:name "Guix's own defaults survive")
                 (assert-true (and (assoc "net.ipv4.tcp_syncookies"
                                          (sysctl-configuration-settings merged))
                                   #t)
                              #:name "and this module's settings are added")
                 (assert-equal #:expect
                               (+ (length wolk-jjba-sysctl-settings)
                                  (length %default-sysctl-settings))
                               #:got
                               (length (sysctl-configuration-settings merged))
                               #:name "Nothing is set twice or dropped")))))

(define (spec)
  (veritas-run sysctl-suite))
