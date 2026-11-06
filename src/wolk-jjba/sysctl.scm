;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Kernel settings, applied once at boot by Guix's sysctl service.
;;
;; The half of a firewall that is not a rule list lives here.  iptables
;; (see (wolk-jjba iptables)) decides what a packet may do; these settings
;; decide how much work the *kernel* does before it gets there.  Without
;; them, a public host that accepts connections from the internet is one
;; SYN flood away from a full accept queue, and one malformed ICMP stream
;; away from spending a core in the protocol stack.
;;
;; Three groups:
;;
;;   SYN flood survival -- syncookies (the SYN queue is never the limit),
;;   a larger SYN backlog and accept queue (a burst is absorbed instead of
;;   dropped), and fewer retries so half-open state expires quickly
;;   instead of accumulating;
;;
;;   anti-spoofing -- strict reverse-path filtering and no source-routed
;;   or redirected packets.  A server that is not a router has no reason
;;   to honour any of them, and honouring them is how this host could be
;;   used to reflect traffic at somebody else;
;;
;;   ICMP -- echo requests are rate limited in the kernel as well as in
;;   iptables, broadcast echo is ignored, and bogus error responses are
;;   not logged (a ping flood must not also be a write flood);
;;
;; plus the two information leaks that cost nothing to close: kernel
;; pointers and the ring buffer are only readable by root, and an
;; unprivileged process may not load BPF programs.
;;
;; Then one group about a *local* attacker rather than a remote one, which
;; is the shape an intrusion takes after a single service is compromised:
;; ptrace limited to a process's own children, perf events root-only,
;; kexec and the magic SysRq keys off, no core dumps from setuid programs,
;; the line-discipline ioctl that lets one terminal write into another not
;; auto-loaded, and planted FIFOs and device files unopenable in a sticky
;; directory.  Logging martians belongs here for the opposite reason: with
;; rp_filter the spoofed packet is dropped anyway, and the log line is the
;; evidence that somebody tried rather than silence.
;;
;; Deliberately *not* here:
;;
;;   - ip_forward and the IPv6 equivalent: rootless Podman sets them
;;     itself, and a value at boot would be overwritten anyway;
;;   - RA / autoconfuted IPv6: NetworkManager owns addresses on this host;
;;   - ptrace_scope, vm.swappiness and other non-network knobs, which
;;     belong to a decision about the machine's role rather than to its
;;     exposure to the internet.
;;
;; The Guix defaults (fs.protected_hardlinks and fs.protected_symlinks)
;; are already in %default-sysctl-settings and are not repeated here.
;;
;; Code:

(define-module (wolk-jjba sysctl)
  #:use-module (gnu)
  #:use-module (gnu services sysctl)
  #:use-module (guix records)
  #:export (wolk-jjba-sysctl-settings extend-sysctl-configuration))

(define-public wolk-jjba-sysctl-settings
  '(;; --- SYN flood survival ------------------------------------------
    ;; Syncookies make the SYN queue length irrelevant under flood: the
    ;; kernel answers without allocating state, and a legitimate client
    ;; completes its handshake normally.
    ("net.ipv4.tcp_syncookies" . "1")
    ;; Backlog and accept queue big enough for a burst of real clients,
    ;; not just for one connection at a time.
    ("net.ipv4.tcp_max_syn_backlog" . "2048")
    ("net.core.somaxconn" . "1024")
    ("net.core.netdev_max_backlog" . "2048")
    ;; Half-open and closing sockets expire in seconds, not in minutes:
    ;; a flood must not be able to keep tens of thousands of entries
    ;; alive for two minutes each.
    ("net.ipv4.tcp_syn_retries" . "3")
    ("net.ipv4.tcp_synack_retries" . "3")
    ("net.ipv4.tcp_fin_timeout" . "15")
    ("net.ipv4.tcp_keepalive_time" . "300")
    ("net.ipv4.tcp_keepalive_intvl" . "30")
    ("net.ipv4.tcp_keepalive_probes" . "5")
    ;; --- anti-spoofing -----------------------------------------------
    ;; Strict reverse-path filtering: a packet claiming to come from an
    ;; address that is not routable back through the interface it arrived
    ;; on is dropped.  Both tables are set, because the per-interface
    ;; default only applies to interfaces created after boot.
    ("net.ipv4.conf.all.rp_filter" . "1")
    ("net.ipv4.conf.default.rp_filter" . "1")
    ("net.ipv4.conf.all.accept_source_route" . "0")
    ("net.ipv4.conf.default.accept_source_route" . "0")
    ("net.ipv6.conf.all.accept_source_route" . "0")
    ("net.ipv6.conf.default.accept_source_route" . "0")
    ;; This is not a router: neither accept nor send ICMP redirects.
    ("net.ipv4.conf.all.accept_redirects" . "0")
    ("net.ipv4.conf.default.accept_redirects" . "0")
    ("net.ipv6.conf.all.accept_redirects" . "0")
    ("net.ipv6.conf.default.accept_redirects" . "0")
    ("net.ipv4.conf.all.secure_redirects" . "0")
    ("net.ipv4.conf.all.send_redirects" . "0")
    ("net.ipv4.conf.default.send_redirects" . "0")
    ;; --- ICMP ---------------------------------------------------------
    ("net.ipv4.icmp_echo_ignore_broadcasts" . "1")
    ("net.ipv4.icmp_ignore_bogus_error_responses" . "1")
    ;; 10 echo replies a second per destination, the same budget the
    ;; iptables rule gives a single source.
    ("net.ipv4.icmp_ratelimit" . "100")
    ("net.ipv4.icmp_ratemask" . "88089")
    ;; --- information leaks --------------------------------------------
    ;; Pointer addresses in /proc, the ring buffer and the symbol tables
    ;; are root-only: they are the first thing a local escalation needs.
    ("kernel.kptr_restrict" . "2")
    ("kernel.dmesg_restrict" . "1")
    ;; A process that is not root may not load BPF programs.  Nothing on
    ;; this host needs to, and an unprivileged BPF verifier is a large
    ;; attack surface.
    ("kernel.unprivileged_bpf_disabled" . "1")
    ;; --- a local attacker, after a service is compromised ---------------
    ;; ptrace is limited to a process's own children.  The classic Linux
    ;; credential theft is attaching to sshd or an agent and reading the
    ;; keys out of its memory, and nothing here debugs another process.
    ("kernel.yama.ptrace_scope" . "1")
    ;; perf events are a profiler and a side channel both, and root can
    ;; still use them; an unprivileged process may not.
    ("kernel.perf_event_paranoid" . "3")
    ;; A compromised root must not be able to boot a kernel of its own, or
    ;; to fire the magic SysRq keys -- there is no console here to press
    ;; them on, and the write path is open to any root tty.
    ("kernel.kexec_load_disabled" . "1")
    ("kernel.sysrq" . "0")
    ;; TIOCSTI lets one terminal push input into another, which is how a
    ;; compromised shell escapes a sandbox; the module is not loaded on
    ;; demand.
    ("dev.tty.ldisc_autoload" . "0")
    ;; A crashing setuid program must not leave its memory in a file.
    ("fs.suid_dumpable" . "0")
    ;; A FIFO or device file planted in /tmp cannot be opened through a
    ;; symlink, or at all by a process that does not own it.
    ("fs.protected_fifos" . "2")
    ("fs.protected_regular" . "2")
    ;; A socket in TIME_WAIT must not accept late segments (RFC 1337).
    ("net.ipv4.tcp_rfc1337" . "1")
    ;; Spoofed sources are dropped by rp_filter above; log them, so the
    ;; attempt is evidence rather than silence.
    ("net.ipv4.conf.all.log_martians" . "1")))

(define-public (extend-sysctl-configuration config)
  "Return CONFIG with the settings above appended to it.

`sysctl-service-type' is already instantiated by (%base-services) with
Guix's %default-sysctl-settings, and the type's extend procedure appends
to whatever settings the configuration holds.  Adding a *second* service
of the same type is therefore the wrong shape: depending on the order the
services are folded in, its value can become the configuration the next
fold inherits, and the boot then fails with

  In procedure struct-vtable: Wrong type argument in position 1

rather than with anything about a kernel setting.  Extending the existing
configuration in config.scm -- the same way log-rotation-service-type is
adjusted there -- leaves exactly one service of the type, with both lists
of settings in it."
  (sysctl-configuration
   (inherit config)
   (settings (append (sysctl-configuration-settings config)
                     wolk-jjba-sysctl-settings))))
