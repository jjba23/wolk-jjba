;;; wolk-jjba

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

;; Commentary:
;;
;; The host firewall.  Only the ports the machine actually serves are
;; opened; everything else is rejected.  Keep this list in sync with
;; the services in config.scm:
;;
;;   2323/tcp   SSH
;;   80/tcp     ACME HTTP-01 and HTTP -> HTTPS redirect
;;   443/tcp    HTTPS
;;   443/udp    HTTP/3 (QUIC)
;;   25565/*    Minecraft
;;   6600/*     MPD
;;   6690/*     Icecast
;;
;; PostgreSQL (5432) and the application upstreams are intentionally
;; not exposed; they are reached through nginx on localhost.  There is
;; no SMTP service on this host, so nothing opens port 25.
;;
;; Code:

(define-module (wolk-jjba iptables)
  #:use-module (gnu)
  #:use-module (gnu services networking))

(define-public wolk-jjba-iptables-service
  (service iptables-service-type
           (iptables-configuration (ipv4-rules (plain-file "iptables.rules"
                                                "*filter
:INPUT ACCEPT
:FORWARD ACCEPT
:OUTPUT ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp --dport 2323 -j ACCEPT
-A INPUT -p tcp --dport 80 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -p udp --dport 443 -j ACCEPT
-A INPUT -p tcp --dport 6600 -j ACCEPT
-A INPUT -p udp --dport 6600 -j ACCEPT
-A INPUT -p tcp --dport 6690 -j ACCEPT
-A INPUT -p udp --dport 6690 -j ACCEPT
-A INPUT -p tcp --dport 25565 -j ACCEPT
-A INPUT -p udp --dport 25565 -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A OUTPUT -p icmp -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-port-unreachable
COMMIT
"))
                                   (ipv6-rules (plain-file "ip6tables.rules"
                                                "*filter
:INPUT ACCEPT
:FORWARD ACCEPT
:OUTPUT ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp --dport 2323 -j ACCEPT
-A INPUT -p tcp --dport 80 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -p udp --dport 443 -j ACCEPT
-A INPUT -p tcp --dport 6600 -j ACCEPT
-A INPUT -p udp --dport 6600 -j ACCEPT
-A INPUT -p tcp --dport 6690 -j ACCEPT
-A INPUT -p udp --dport 6690 -j ACCEPT
-A INPUT -p tcp --dport 25565 -j ACCEPT
-A INPUT -p udp --dport 25565 -j ACCEPT
-A INPUT -p icmpv6 -j ACCEPT
-A OUTPUT -p icmpv6 -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -j REJECT --reject-with icmp6-port-unreachable
COMMIT
")))))
