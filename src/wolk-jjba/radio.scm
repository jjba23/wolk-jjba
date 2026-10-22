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

;; Commentary:
;;
;; The radio: MPD reads the library from the Storage Box over CIFS and
;; encodes it into Icecast, which serves the stream.  This module owns
;; everything that makes that chain survive being listened to from a
;; phone on a moving train.
;;
;; Three decisions shape it.
;;
;; *One library, three streams.*  A single MPD instance encodes the same
;; audio into three mounts at the same time: 128 kbit/s Opus for a
;; decent connection, 64 kbit/s Opus for mobile data (still good
;; quality, roughly half the bytes), and a 96 kbit/s MP3 mount because
;; every phone, car radio and browser plays MP3 while Ogg-Opus is
;; missing from Safari's HTML5 player.  Clients pick a mount; nothing
;; else differs.
;;
;; *The stream is a long-lived connection, not a file.*  Icecast stays
;; on 6690 for direct use, and nginx also proxies it at
;; https://jointhefreeworld.org/radio/ with buffering off, HTTP/2 and
;; HTTP/3 (QUIC reaches a phone on a lossy link better than TCP does)
;; and a long read timeout.  Icecast's burst and queue sizes are raised
;; from their defaults so a client on a high-latency mobile link fills
;; its buffer in one go instead of stuttering through the first minute.
;;
;; *A stream that is not watched dies silently.*  `radio-health' runs
;; every five minutes, publishes what it found as Prometheus textfile
;; metrics and, after three bad checks in a row (a Storage Box that is
;; briefly unreachable should not interrupt anyone), restarts Icecast
;; and then MPD.  `mpd-scan' refreshes the library database nightly,
;; because inotify does not follow a CIFS mount: files added on the
;; Storage Box are invisible to MPD until something walks the tree.
;;
;; Secrets.  The Icecast source and admin passwords are read from
;; /etc/secrets by config.scm before this module is called; the health
;; and scan jobs read the MPD password themselves at run time, so no
;; password is written into a job script.
;;
;; Code:

(define-module (wolk-jjba radio)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix gexp)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services audio)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages xiph)
  #:use-module (ice-9 format)
  #:use-module (wolk-jjba jobs)
  #:use-module (wolk-jjba maintenance)
  #:export (radio-library-directory
            radio-library-mount-point
            radio-icecast-port
            radio-mpd-port
            radio-streams
            radio-mpd-configuration
            icecast-config-file
            icecast-config-text
            icecast-shepherd-service
            radio-health-job
            radio-scan-job
            radio-health-service
            radio-scan-service
            radio-log-files
            radio-capability))

;; ====== Where the music is ======

(define radio-library-mount-point
  "/mnt/wolkenschlosslagerung")

(define radio-library-directory
  (string-append radio-library-mount-point "/music"))

(define radio-icecast-port
  6690)

(define radio-mpd-port
  6600)

;; ====== The streams ======
;;
;; Each entry is (mount encoder bitrate description).  The mount name is
;; what a listener puts after the host -- /radio.opus,
;; /radio-low.opus, /radio.mp3 -- and it is also the label of every
;; metric and alert, so a name here is part of the operator interface:
;; renaming a mount breaks bookmarks and dashboards.
;;
;; The mobile mount earns its place: at 64 kbit/s Opus a three-minute
;; track is about 1.4 MB against 2.9 MB for the 128k mount, and on a
;; phone that difference is the whole point.  The MP3 mount is not about
;; quality -- 96 kbit/s MP3 is audibly worse -- it is about reach.
(define radio-streams
  '(("radio.opus" "opus" "128000" "wolk-jjba radio")
    ("radio-low.opus" "opus" "64000" "wolk-jjba radio (low, mobile data)")
    ("radio.mp3" "lame" "96000" "wolk-jjba radio (MP3)")))

(define (stream-mount stream)
  (car stream))

(define (stream-encoder stream)
  (cadr stream))

(define (stream-bitrate stream)
  (caddr stream))

(define (stream-name stream)
  (cadddr stream))

;; ====== MPD ======

(define* (radio-output stream
                       #:key
                       (source-password "")
                       (icecast-host "127.0.0.1")
                       (icecast-port radio-icecast-port))
  "Return the MPD audio output that encodes STREAM into Icecast.

`always-on? #t' is what keeps listeners attached when nothing is
playing: without it MPD closes the shout connection as soon as playback
stops, every listener is dropped, and a phone has to reconnect and
buffer again for the next track.  With it, the silence is streamed and
the client never notices."
  (mpd-output
   (name (stream-name stream))
   (type "shout")
   (format "48000:16:2")
   (always-on? #t)
   (extra-options
    `((host . ,icecast-host)
      (port . ,(number->string icecast-port))
      (mount . ,(string-append "/" (stream-mount stream)))
      (password . ,source-password)
      (encoder . ,(stream-encoder stream))
      (bitrate . ,(stream-bitrate stream))
      (genre . "Various")
      (public . "no")))))

(define* (radio-mpd-configuration #:key
                                  (music-directory radio-library-directory)
                                  (source-password "")
                                  (admin-password "")
                                  (read-password "")
                                  (streams radio-streams)
                                  (icecast-host "127.0.0.1")
                                  (icecast-port radio-icecast-port)
                                  (audio-buffer-size 8192))
  "Return the MPD configuration of the radio.

Two details are about surviving this host rather than about MPD:

- the database, the state file and the playlists live on local disk
  (/var/lib/mpd) and not on the CIFS mount.  The library is the mount;
  the index of the library must not be, or a network blip takes the
  queue with it.  The state file is also what makes a watchdog restart
  harmless: MPD comes back with the same queue, in the same position;
- `audio_buffer_size' is raised from its 4 MiB default to 8 MiB, so a
  slow read from the Storage Box is absorbed by already-decoded audio
  instead of being heard as a gap."
  (mpd-configuration
   (music-directory music-directory)
   (db-file "/var/lib/mpd/tag_cache")
   (state-file "/var/lib/mpd/state")
   (sticker-file "/var/lib/mpd/sticker.sql")
   (playlist-directory "/var/lib/mpd/playlists")
   (outputs (map (lambda (stream)
                   (radio-output stream
                                 #:source-password source-password
                                 #:icecast-host icecast-host
                                 #:icecast-port icecast-port))
                 streams))
   (decoders (list (mpd-plugin (plugin "mikmod") (enabled? #t))
                   (mpd-plugin (plugin "openmpt")
                               (enabled? #t)
                               (extra-options `((repeat-count . -1)
                                                (interpolation-filter . 1))))))
   (resampler (mpd-plugin (plugin "libsamplerate")
                          (extra-options `((type . 0)))))
   (auto-update? #t)
   (extra-options
    `((password . ,(format #f "~a@read,add,control,admin" admin-password))
      (password . ,(format #f "~a@read,add,control" read-password))
      (audio_buffer_size . ,(number->string audio-buffer-size))))))

;; ====== Icecast ======

(define (xml-escape text)
  "Return TEXT with the five XML metacharacters escaped.

The passwords this file carries are base64 today, which needs no
escaping, but a passphrase pasted from a password manager can contain
`&' or `<' -- and then Icecast refuses to start with a parse error that
names a line instead of a cause."
  (string-replace-substring
   (string-replace-substring
    (string-replace-substring
     (string-replace-substring
      (string-replace-substring text "&" "&amp;")
      "<" "&lt;")
     ">" "&gt;")
    "\"" "&quot;")
   "'" "&apos;"))

(define* (icecast-config-text #:key
                              (source-password "")
                              (admin-password "")
                              (admin-user "admin")
                              (admin-email "jjbigorra@gmail.com")
                              (location "Amsterdam")
                              (hostname "jointhefreeworld.org")
                              (port radio-icecast-port)
                              (webroot "@WEBROOT@")
                              (adminroot "@ADMINROOT@")
                              (log-directory "/var/log/icecast")
                              (clients 100)
                              (sources 4)
                              (queue-size 1048576)
                              (burst-size 131072))
  "Return the text of icecast.xml.

BURST-SIZE and QUEUE-SIZE are the two numbers that decide how a phone on
mobile data starts.  Icecast's default burst is 64 KiB, about four
seconds at 128 kbit/s: enough for a desktop on a wired link, and a
stutter for the first half minute on a train, because the client has
only four seconds of slack while the link renegotiates.  128 KiB (about
eight seconds) fills a mobile client's buffer in one burst, and the
queue has to hold at least two bursts for that to be possible, hence
1 MiB.

The web and admin roots are placeholders here and are substituted with
the real store paths by `icecast-config-file'; the web root is what
makes /status.xsl -- and therefore the health page behind /radio/ --
work at all."
  (format #f "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!-- Generated by (wolk-jjba radio); do not edit by hand. -->
<icecast>
    <location>~a</location>
    <admin>~a</admin>
    <hostname>~a</hostname>

    <authentication>
        <source-password>~a</source-password>
        <admin-user>~a</admin-user>
        <admin-password>~a</admin-password>
    </authentication>

    <limits>
        <clients>~a</clients>
        <sources>~a</sources>
        <queue-size>~a</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <burst-on-connect>1</burst-on-connect>
        <burst-size>~a</burst-size>
    </limits>

    <listen-socket>
        <port>~a</port>
        <bind-address>0.0.0.0</bind-address>
    </listen-socket>

    <paths>
        <logdir>~a</logdir>
        <webroot>~a</webroot>
        <adminroot>~a</adminroot>
        <alias source=\"/\" destination=\"/status.xsl\"/>
    </paths>

    <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>3</loglevel>
    </logging>

    <security>
        <chroot>0</chroot>
    </security>
</icecast>
"
          (xml-escape location)
          (xml-escape admin-email)
          (xml-escape hostname)
          (xml-escape source-password)
          (xml-escape admin-user)
          (xml-escape admin-password)
          clients
          sources
          queue-size
          burst-size
          port
          (xml-escape log-directory)
          webroot
          adminroot))

(define* (icecast-config-file #:key
                              (source-password "")
                              (admin-password "")
                              (hostname "jointhefreeworld.org")
                              (port radio-icecast-port))
  "Return the icecast.xml store item, with the packaged web and admin
trees spliced in."
  (computed-file "icecast.xml"
    #~(begin
        (use-modules (ice-9 string-fun))
        (call-with-output-file #$output
          (lambda (port)
            (display (string-replace-substring
                      (string-replace-substring
                       #$(icecast-config-text #:source-password source-password
                                              #:admin-password admin-password
                                              #:hostname hostname
                                              #:port port)
                       "@WEBROOT@"
                       #$(file-append icecast "/share/icecast/web"))
                      "@ADMINROOT@"
                      #$(file-append icecast "/share/icecast/admin"))
                     port))))))

(define* (icecast-shepherd-service #:key
                                   (source-password "")
                                   (admin-password "")
                                   (hostname "jointhefreeworld.org")
                                   (port radio-icecast-port))
  "Return the service that runs Icecast with the generated config.

Icecast writes its own access and error logs into /var/log/icecast; they
are registered for rotation by `radio-log-files' below, because nothing
else in the system knows those files exist and an unrotated access log
from a public stream grows without bound."
  (let ((config (icecast-config-file #:source-password source-password
                                     #:admin-password admin-password
                                     #:hostname hostname
                                     #:port port)))
    (simple-service 'wolk-jjba-icecast shepherd-root-service-type
                    (list (shepherd-service
                           (documentation
                            "Run the Icecast streaming media server.")
                           (provision '(icecast))
                           (requirement '(networking user-homes))
                           (start #~(lambda args
                                      ;; Icecast creates neither its log
                                      ;; directory nor the files in it;
                                      ;; the Shepherd starts this as root
                                      ;; and drops to the `icecast' user.
                                      (mkdir-p "/var/log/icecast")
                                      (mkdir-p "/var/log/wolk-jjba")
                                      (let ((pw (getpwnam "icecast")))
                                        (when pw
                                          (chown "/var/log/icecast"
                                                 (passwd:uid pw)
                                                 (passwd:gid pw))))
                                      ((make-forkexec-constructor
                                        (list #$(file-append icecast
                                                             "/bin/icecast")
                                              "-c"
                                              #$config)
                                        #:log-file
                                        "/var/log/wolk-jjba/icecast.log"
                                        #:user "icecast"
                                        #:group "icecast")
                                       args)))
                           (stop #~(make-kill-destructor))
                           (respawn? #t))))))

;; ====== Health and metrics ======

(define* (radio-health-job #:key
                           (icecast-url "http://127.0.0.1:6690")
                           (mpd-host "127.0.0.1")
                           (mpd-port radio-mpd-port)
                           (mount-point radio-library-mount-point)
                           (secrets-directory "/etc/secrets")
                           (streams radio-streams)
                           (state-directory "/var/lib/wolk-radio")
                           (restart-after 3))
  "Return the script of the five-minute radio check.

It does three things in one pass, because they all need the same three
answers (is the library mounted, is MPD listening, is Icecast
answering):

1. publishes what it found as Prometheus textfile metrics -- sources
   per mount, listeners, peak, bitrate, whether the library is mounted,
   whether MPD answers, and whether it is playing;
2. counts consecutive failures in STATE-DIRECTORY, so a Storage Box
   that is unreachable for a minute does not interrupt anyone: one bad
   check is expected on this host, RESTART-AFTER of them in a row is
   not;
3. restarts Icecast and then MPD once that threshold is reached -- in
   that order, because an MPD that reconnects to a dead Icecast just
   fails its shout connection again.

The MPD password is read from SECRETS-DIRECTORY at run time, so it never
lands in a store item that is world-readable."
  (let ((expected-mounts (string-join (map stream-mount streams) " ")))
    (string-append
     (textfile-script
      "wolk_radio.prom"
      (format #f "STATE_DIR=~a
SECRETS_DIR=~a
MOUNT_POINT=~a
ICECAST=~a
EXPECTED=\"~a\"
mkdir -p \"$STATE_DIR\"

library_mounted=0
mountpoint -q \"$MOUNT_POINT\" && library_mounted=1

mpd_up=0
if timeout 3 bash -c \"exec 3<>/dev/tcp/~a/~a\" 2>/dev/null; then
  mpd_up=1
fi

status_json=\"$(curl -fsS --max-time 5 \"$ICECAST/status-json.xsl\" 2>/dev/null || true)\"
icecast_up=0
[ -n \"$status_json\" ] && icecast_up=1
[ -z \"$status_json\" ] && status_json='{}'

PY=$(cat <<'PYTHON'
import json, os, sys

expected = os.environ.get(\"EXPECTED\", \"\").split()
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

stats = data.get(\"icestats\") if isinstance(data, dict) else None
if not isinstance(stats, dict):
    stats = {}
raw = stats.get(\"source\")
if isinstance(raw, dict):
    raw = [raw]
elif not isinstance(raw, list):
    raw = []

found = {}
for source in raw:
    if not isinstance(source, dict):
        continue
    url = source.get(\"listenurl\") or \"\"
    mount = url.split(\"?\")[0].rstrip(\"/\").split(\"/\")[-1]
    if mount:
        found[mount] = source

print(\"# HELP wolk_radio_source_connected Whether a source is connected to the mount.\")
print(\"# TYPE wolk_radio_source_connected gauge\")
print(\"# HELP wolk_radio_listeners Listeners currently connected to the mount.\")
print(\"# TYPE wolk_radio_listeners gauge\")
print(\"# HELP wolk_radio_listener_peak Highest listener count since the source connected.\")
print(\"# TYPE wolk_radio_listener_peak gauge\")
print(\"# HELP wolk_radio_bitrate_kbps Bitrate of the mount, in kbit/s.\")
print(\"# TYPE wolk_radio_bitrate_kbps gauge\")

listeners_total = 0
connected_total = 0
for mount in expected:
    source = found.get(mount)
    connected = 1 if source else 0
    listeners = 0
    peak = 0
    bitrate = 0
    if source:
        connected_total += 1
        try:
            listeners = int(source.get(\"listeners\") or 0)
            peak = int(source.get(\"listener_peak\") or 0)
        except (TypeError, ValueError):
            listeners = 0
        bitrate = source.get(\"ice-bitrate\") or source.get(\"bitrate\") or 0
        listeners_total += listeners
    print('wolk_radio_source_connected{mount=\"%s\"} %d' % (mount, connected))
    print('wolk_radio_listeners{mount=\"%s\"} %d' % (mount, listeners))
    print('wolk_radio_listener_peak{mount=\"%s\"} %d' % (mount, peak))
    print('wolk_radio_bitrate_kbps{mount=\"%s\"} %s' % (mount, bitrate))

facts = os.environ.get(\"FACTS\")
if facts:
    with open(facts, \"w\") as handle:
        handle.write(\"sources=%d\\n\" % connected_total)
        handle.write(\"listeners=%d\\n\" % listeners_total)
PYTHON
)

FACTS=\"$STATE_DIR/facts\"
printf '%s' \"$status_json\" | EXPECTED=\"$EXPECTED\" FACTS=\"$FACTS\" python3 -c \"$PY\"

sources=0
listeners=0
if [ -f \"$FACTS\" ]; then
  . \"$FACTS\"
fi

mpd_state=\"\"
mpd_songs=\"\"
if [ -r \"$SECRETS_DIR/mpd-admin\" ] && command -v mpc >/dev/null 2>&1; then
  mpd_password=$(head -n 1 \"$SECRETS_DIR/mpd-admin\")
  export MPD_HOST=\"$mpd_password@~a\"
  # mpc takes a format string for the one value we want; parsing its
  # human output instead would break the day the columns move.
  # MPD refuses every command until a client authenticates (\"you don't
  # have permission for status\"), which is why the password comes from
  # the secret file rather than from the script.
  mpd_state=$(mpc -p ~a status %state% 2>/dev/null | head -n 1)
  mpd_songs=$(mpc -p ~a stats 2>/dev/null | awk -F': *' '/^Songs:/ { print $2 }' | head -n 1)
fi

mpd_playing=\"\"
case \"$mpd_state\" in
  playing) mpd_playing=1 ;;
  paused|stopped) mpd_playing=0 ;;
  *) mpd_playing=\"\" ;;
esac

printf '# HELP wolk_radio_up Whether Icecast answered on its status endpoint.\\n'
printf '# TYPE wolk_radio_up gauge\\n'
printf 'wolk_radio_up %s\\n' \"$icecast_up\"
printf '# HELP wolk_mpd_up Whether MPD accepts connections.\\n'
printf '# TYPE wolk_mpd_up gauge\\n'
printf 'wolk_mpd_up %s\\n' \"$mpd_up\"
printf '# HELP wolk_radio_library_mounted Whether the music library is mounted.\\n'
printf '# TYPE wolk_radio_library_mounted gauge\\n'
printf 'wolk_radio_library_mounted %s\\n' \"$library_mounted\"
printf '# HELP wolk_radio_listeners_total Listeners across the expected mounts.\\n'
printf '# TYPE wolk_radio_listeners_total gauge\\n'
printf 'wolk_radio_listeners_total %s\\n' \"$listeners\"
if [ -n \"$mpd_playing\" ]; then
  printf '# HELP wolk_mpd_playing Whether MPD is playing (absent when it cannot be asked).\\n'
  printf '# TYPE wolk_mpd_playing gauge\\n'
  printf 'wolk_mpd_playing %s\\n' \"$mpd_playing\"
fi
if [ -n \"$mpd_songs\" ]; then
  printf '# HELP wolk_mpd_songs Songs in the MPD database (absent when MPD cannot be asked).\\n'
  printf '# TYPE wolk_mpd_songs gauge\\n'
  printf 'wolk_mpd_songs %s\\n' \"$mpd_songs\"
fi
printf '# HELP wolk_radio_check_timestamp_seconds When the radio check last ran.\\n'
printf '# TYPE wolk_radio_check_timestamp_seconds gauge\\n'
printf 'wolk_radio_check_timestamp_seconds %s\\n' \"$(date +%s)\"

failures=0
[ -f \"$STATE_DIR/failures\" ] && failures=$(cat \"$STATE_DIR/failures\" 2>/dev/null || echo 0)
expected_total=$(printf '%s\\n' $EXPECTED | wc -l)
broken=0
[ \"$icecast_up\" -eq 0 ] && broken=1
[ \"$mpd_up\" -eq 0 ] && broken=1
[ \"$library_mounted\" -eq 1 ] && [ \"$sources\" -lt \"$expected_total\" ] && broken=1
if [ \"$broken\" -eq 1 ]; then
  failures=$((failures + 1))
  echo \"radio check: bad (icecast=$icecast_up mpd=$mpd_up mounted=$library_mounted sources=$sources/$expected_total) consecutive=$failures\" >&2
else
  failures=0
fi
echo \"$failures\" > \"$STATE_DIR/failures\"

# An empty database next to a mounted library is what a first boot (or an
# MPD that came up before the CIFS mount) looks like: MPD logs
# \"Database corrupted\", starts with nothing, and stays silent until
# something walks the tree.  One update beats waiting for the nightly
# scan, and it costs nothing on a database that already has songs.
if [ \"$library_mounted\" -eq 1 ] && [ -n \"$mpd_songs\" ] && [ \"$mpd_songs\" -eq 0 ]; then
  echo \"radio check: MPD database is empty, running an update\" >&2
  # `mpc update --wait' prints the player status when it is done; on
  # stdout that would land in the .prom file and node exporter would
  # reject every line in it.
  mpc -p ~a update --wait >&2 || true
fi

if [ \"$failures\" -ge ~a ]; then
  echo \"radio check: restarting icecast and mpd after $failures bad checks\" >&2
  herd restart icecast || true
  sleep 3
  herd restart mpd || true
  echo 0 > \"$STATE_DIR/failures\"
fi"
              state-directory
              secrets-directory
              mount-point
              icecast-url
              expected-mounts
              mpd-host
              mpd-port
              mpd-host
              mpd-port
              mpd-port
              mpd-port
              restart-after))
     "\nexit 0\n")))

(define* (radio-scan-job #:key
                         (mpd-host "127.0.0.1")
                         (mpd-port radio-mpd-port)
                         (mount-point radio-library-mount-point)
                         (secrets-directory "/etc/secrets"))
  "Return the script that refreshes the MPD library database.

inotify does not cross a CIFS mount in any useful way: a file added to
the Storage Box from a laptop never wakes MPD up, so `auto-update' only
notices changes made on this host.  A nightly `update --wait' walks the
tree once, which is the difference between \"the album I just uploaded
appears tomorrow\" and \"the album never appears\".

The scan is skipped when the library is not mounted: an update over a
missing mount would empty the database of files that are still there."
  (format #f "set -uo pipefail
if ! mountpoint -q ~a; then
  echo 'mpd-scan: ~a is not mounted, skipping the scan' >&2
  exit 0
fi
if [ ! -r ~a/mpd-admin ]; then
  echo 'mpd-scan: cannot read ~a/mpd-admin' >&2
  exit 1
fi
mpd_password=$(head -n 1 ~a/mpd-admin)
export MPD_HOST=\"$mpd_password@~a\"
mpc -p ~a update --wait || true
mpc -p ~a stats | sed 's/^/mpd-scan: /' || true"
          mount-point
          mount-point
          secrets-directory
          secrets-directory
          secrets-directory
          mpd-host
          mpd-port
          mpd-port))

(define radio-health-service
  (make-timer-service
   #:name 'radio-health
   #:schedule "*/5 * * * *"
   #:script (radio-health-job)
   #:max-duration 300
   #:documentation
   "Check the radio, publish its metrics and repair it when it is broken."))

(define radio-scan-service
  (make-timer-service
   #:name 'mpd-scan
   #:schedule "20 4 * * *"
   #:script (radio-scan-job)
   #:max-duration 7200
   #:documentation
   "Refresh the MPD library database from the Storage Box."))

(define radio-log-files
  '("/var/log/icecast/access.log"
    "/var/log/icecast/error.log"
    "/var/log/wolk-jjba/radio-health.log"
    "/var/log/wolk-jjba/mpd-scan.log"))

;; ====== Service type ======

(define radio-service-type
  (service-type
   (name 'wolk-jjba-radio)
   (extensions
    (list (service-extension
           shepherd-root-service-type
           (const (list radio-health-service radio-scan-service)))
          (service-extension
           account-service-type
           (const (list (user-group (name "icecast") (system? #t))
                        (user-account
                         (name "icecast")
                         (group "icecast")
                         (system? #t)
                         (comment "Icecast Service User")
                         (home-directory "/var/run/icecast")
                         (shell (file-append shadow "/sbin/nologin"))))))
          (service-extension
           activation-service-type
           (const #~(begin
                      (use-modules (guix build utils))
                      ;; MPD's own activation creates the parents of the
                      ;; database and state files but not the playlist
                      ;; directory; the health job also keeps its
                      ;; failure counter in a directory of its own.
                      (mkdir-p "/var/lib/mpd/playlists")
                      (mkdir-p "/var/lib/wolk-radio")
                      (chmod "/var/lib/wolk-radio" #o755)
                      (let ((pw (getpwnam "mpd")))
                        (when pw
                          (chown "/var/lib/mpd/playlists"
                                 (passwd:uid pw)
                                 (passwd:gid pw)))))))
          (service-extension
           log-rotation-service-type
           (const radio-log-files))))
   (default-value '())
   (description
    "Run the MPD + Icecast radio, keep it alive, and publish its metrics
as Shepherd timer jobs.")))

(define (radio-capability)
  (service radio-service-type))
