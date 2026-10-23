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
;; An open port is not the same as a served port, though, and this is a
;; public host somebody else's automation finds within minutes.  So the
;; ruleset is layered, and the layers are cheap enough to run on every
;; packet:
;;
;;   1. -i lo is trusted, then conntrack INVALID is dropped: malformed
;;      and out-of-window packets are not a service, they are an attempt
;;      to get the kernel (or a buggy stack) to spend time on them;
;;   2. per-source *rate* limits on new connections: SSH gets 20 new
;;      connections a minute with a burst of 30 -- a password guesser
;;      needs orders of magnitude more, and one `ssh' from a laptop needs
;;      one (scp, mosh, tunnels and a git push over ssh still fit);
;;   3. per-source *concurrency* limits (connlimit): a single address may
;;      hold 8 SSH, 40 HTTP, 60 HTTPS, 20 Icecast or 20 Minecraft/TCP
;;      connections at once.  This is what stops one machine from
;;      occupying the whole accept queue with half-open or slowloris
;;      connections;
;;   4. ICMP echo is rate limited to 10 a second per host, so a ping
;;      flood cannot be used to burn CPU in the ICMP path.  Everything
;;      else ICMP carries (path MTU, unreachables) is still accepted;
;;   5. the port ACCEPTs, then ESTABLISHED,RELATED, then REJECT.
;;
;; Loopback traffic is accepted first, which is also what keeps the
;; proxied radio working: nginx connects to Icecast on 127.0.0.1:6690, so
;; the connlimit on 6690 counts only direct external listeners and never
;; the listeners arriving through https://jointhefreeworld.org/radio/.
;;
;; TCP SYN flood protection lives in the kernel, not here: see the
;; `tcp_syncookies' and `tcp_max_syn_backlog' settings added in
;; config.scm (sysctl-service-type).
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
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -p tcp --dport 2323 -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 20/minute --hashlimit-burst 30 --hashlimit-mode srcip --hashlimit-name ssh-new -j DROP
-A INPUT -p tcp --dport 2323 -m connlimit --connlimit-above 8 -j REJECT --reject-with tcp-reset
-A INPUT -p tcp --dport 80 -m connlimit --connlimit-above 40 -j REJECT --reject-with tcp-reset
-A INPUT -p tcp --dport 443 -m connlimit --connlimit-above 60 -j REJECT --reject-with tcp-reset
-A INPUT -p udp --dport 443 -m connlimit --connlimit-above 60 -j REJECT --reject-with icmp-port-unreachable
-A INPUT -p tcp --dport 6690 -m connlimit --connlimit-above 20 -j REJECT --reject-with tcp-reset
-A INPUT -p tcp --dport 6600 -m connlimit --connlimit-above 8 -j REJECT --reject-with tcp-reset
-A INPUT -p tcp --dport 25565 -m connlimit --connlimit-above 20 -j REJECT --reject-with tcp-reset
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 10/second --limit-burst 20 -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -j DROP
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
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -p tcp --dport 2323 -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 20/minute --hashlimit-burst 30 --hashlimit-mode srcip --hashlimit-name ssh-new6 -j DROP
-A INPUT -p tcp --dport 2323 -m connlimit --connlimit-above 8 -j REJECT --reject-with tcp-reset
-A INPUT -p tcp --dport 80 -m connlimit --connlimit-above 40 -j REJECT --reject-with tcp-reset
-A INPUT -p tcp --dport 443 -m connlimit --connlimit-above 60 -j REJECT --reject-with tcp-reset
-A INPUT -p udp --dport 443 -m connlimit --connlimit-above 60 -j REJECT --reject-with icmp6-port-unreachable
-A INPUT -p tcp --dport 6690 -m connlimit --connlimit-above 20 -j REJECT --reject-with tcp-reset
-A INPUT -p tcp --dport 6600 -m connlimit --connlimit-above 8 -j REJECT --reject-with tcp-reset
-A INPUT -p tcp --dport 25565 -m connlimit --connlimit-above 20 -j REJECT --reject-with tcp-reset
-A INPUT -p icmpv6 --icmpv6-type echo-request -m limit --limit 10/second --limit-burst 20 -j ACCEPT
-A INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
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
