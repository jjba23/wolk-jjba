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

;;; Commentary:
;;
;; Unit tests for (wolk-jjba iptables).  The rules are a plain file, so
;; the tests read that file: the ports the machine means to serve are
;; open, the loopback is trusted, established connections come back in,
;; everything else is rejected, and no port that is supposed to stay
;; private -- PostgreSQL, the application upstreams -- is opened by
;; accident.

;;; Code:

(define-module (veritas unit iptables-spec)
  #:use-module (veritas veritas)
  #:use-module (guix)
  #:use-module (gnu services)
  #:use-module (gnu services networking)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba iptables)
  #:export (spec))

(define configuration (service-value wolk-jjba-iptables-service))

(define ipv4-rules-of
  (@@ (gnu services networking) iptables-configuration-ipv4-rules))
(define ipv6-rules-of
  (@@ (gnu services networking) iptables-configuration-ipv6-rules))

(define ipv4
  (plain-file-content (ipv4-rules-of configuration)))

(define ipv6
  (plain-file-content (ipv6-rules-of configuration)))

(define ipv4-lines (string-split ipv4 #\newline))
(define ipv6-lines (string-split ipv6 #\newline))

(define (some? predicate items)
  "Return #t when PREDICATE holds for some of ITEMS."
  (and (any predicate items) #t))

(define (opens? lines protocol port)
  "Return #t when LINES accept inbound traffic on PROTOCOL and PORT."
  (some? (lambda (line)
           (and (string-contains line (string-append "-A INPUT -p " protocol))
                (string-contains line (string-append "--dport " port " "))
                (string-contains line "-j ACCEPT")))
         lines))

(define iptables-suite
  (suite "Firewall Suite"

         (test "Both rule sets exist and are balanced"
               (assert-true (and (> (length ipv4-lines) 10) #t)
                            #:name "The IPv4 rule set is not empty")
               (assert-true (and (> (length ipv6-lines) 10) #t)
                            #:name "The IPv6 rule set is not empty")
               (assert-equal #:expect 1
                             #:got
                             (length (filter (lambda (line)
                                               (string-contains line "COMMIT"))
                                             ipv4-lines))
                             #:name "IPv4 commits exactly once")
               (assert-equal #:expect 1
                             #:got
                             (length (filter (lambda (line)
                                               (string-contains line "COMMIT"))
                                             ipv6-lines))
                             #:name "IPv6 commits exactly once"))

         (test "The served ports are open"
               (assert-true (opens? ipv4-lines "tcp" "2323")
                            #:name "SSH is on 2323")
               (assert-true (opens? ipv4-lines "tcp" "80")
                            #:name "HTTP is open for ACME challenges")
               (assert-true (opens? ipv4-lines "tcp" "443")
                            #:name "HTTPS is open")
               (assert-true (opens? ipv4-lines "udp" "443")
                            #:name "HTTP/3 is open")
               (assert-true (opens? ipv4-lines "tcp" "6690")
                            #:name "Icecast is open")
               (assert-true (opens? ipv4-lines "udp" "6690")
                            #:name "Icecast sees UDP sources")
               (assert-true (opens? ipv4-lines "tcp" "25565")
                            #:name "Minecraft is open")
               (assert-true (opens? ipv4-lines "udp" "25565")
                            #:name "Minecraft sees UDP"))

         (test "Private services stay closed"
               (assert-false (opens? ipv4-lines "tcp" "5432")
                             #:name "PostgreSQL is not exposed")
               (assert-false (opens? ipv4-lines "tcp" "53000")
                             #:name "Grafana is reached through nginx only")
               (assert-false (opens? ipv4-lines "tcp" "59090")
                             #:name "Prometheus is reached through nginx only")
               (assert-false (opens? ipv4-lines "tcp" "50025")
                             #:name "The lucidplan upstream is not exposed"))

         (test "The rules are a default-deny set"
               (assert-true (some? (lambda (line)
                                     (string-contains line "-i lo -j ACCEPT"))
                                   ipv4-lines)
                            #:name "The loopback is trusted")
               (assert-true (some? (lambda (line)
                                     (string-contains line
                                                      "--ctstate ESTABLISHED,RELATED -j ACCEPT"))
                                   ipv4-lines)
                            #:name "Replies to outbound connections are allowed")
               (assert-true (some? (lambda (line)
                                     (string-contains line
                                                      "-j REJECT --reject-with icmp-port-unreachable"))
                                   ipv4-lines)
                            #:name "Everything else is rejected")
               (assert-true (some? (lambda (line)
                                     (string-contains line
                                                      "-j REJECT --reject-with icmp6-port-unreachable"))
                                   ipv6-lines)
                            #:name "IPv6 rejects with the IPv6 ICMP type"))

                  (test "IPv6 mirrors IPv4"
                        (assert-true (opens? ipv6-lines "tcp" "443")
                                     #:name "IPv6 serves HTTPS")
                        (assert-true (opens? ipv6-lines "tcp" "2323")
                                     #:name "IPv6 serves SSH")
                        (assert-true (some? (lambda (line)
                                              (string-contains line "-p icmpv6 -j ACCEPT"))
                                            ipv6-lines)
                                     #:name "IPv6 accepts ICMPv6")
                        (assert-false (opens? ipv6-lines "tcp" "5432")
                                      #:name "IPv6 does not expose PostgreSQL"))
         
                  (test "Hostile traffic is bounded before it reaches a service"
                        (assert-true (some? (lambda (line)
                                              (and (string-contains line
                                                                    "--ctstate INVALID")
                                                   (string-contains line "-j DROP")))
                                            ipv4-lines)
                                     #:name "Malformed packets are dropped, not parsed")
                        (assert-true (every (lambda (port)
                                              (some? (lambda (line)
                                                       (and (string-contains
                                                             line
                                                             (string-append "--dport " port " "))
                                                            (string-contains line "hashlimit-above")
                                                            (string-contains line "-j DROP")))
                                                     ipv4-lines))
                                            '("2323"))
                                     #:name "New SSH connections are rate limited per source")
                        (assert-true (every (lambda (port)
                                              (some? (lambda (line)
                                                       (and (string-contains
                                                             line
                                                             (string-append "--dport " port " "))
                                                            (string-contains line "connlimit")
                                                            (string-contains line "REJECT")))
                                                     ipv4-lines))
                                            '("2323" "80" "443" "6690" "6600" "25565"))
                                     #:name "Every served port has a per-source connection cap")
                        (assert-true (some? (lambda (line)
                                              (and (string-contains line "icmp-type echo-request")
                                                   (string-contains line "limit")
                                                   (string-contains line "-j ACCEPT")))
                                            ipv4-lines)
                                     #:name "ICMP echo is rate limited before it is accepted")
                        (assert-true (some? (lambda (line)
                                              (and (string-contains line "icmp-type echo-request")
                                                   (string-contains line "-j DROP")))
                                            ipv4-lines)
                                     #:name "and the excess is dropped, not queued")
                        (assert-true (some? (lambda (line)
                                              (and (string-contains line
                                                                    "--ctstate INVALID")
                                                   (string-contains line "-j DROP")))
                                            ipv6-lines)
                                     #:name "IPv6 drops malformed packets too")
                        (assert-true (some? (lambda (line)
                                              (and (string-contains line "connlimit")
                                                   (string-contains line "--dport 443 ")))
                                            ipv6-lines)
                                     #:name "IPv6 caps connections per source"))))

(define (spec)
  (veritas-run iptables-suite))
