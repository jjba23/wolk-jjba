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
;; Unit tests for (wolk-jjba radio): the MPD + Icecast stream.
;;
;; What is worth testing here is the part that cannot be seen until it
;; is live.  The stream is one long-lived connection from a phone to a
;; daemon that reads its files over the network, so the failures are
;; quiet: a mount that is not being pushed into, a database that is
;; empty because a scan never ran, a password that MPD no longer knows,
;; a proxy that buffers the audio instead of forwarding it.
;;
;; Four groups:
;;
;;   - the configuration: three mounts with the right encoders and
;;     bitrates, always-on outputs, a local database and state file, and
;;     no literal password anywhere;
;;   - the health job: it must authenticate (MPD refuses every command
;;     until it does), probe all the expected mounts, leave a paused or
;;     stopped player exactly as it found it, start one only when the
;;     queue is empty, and restart the daemons only after repeated
;;     failures of the kind a restart actually fixes -- never bouncing a
;;     paused MPD, which would put the music back on;
;;   - the scan job: it must skip an unmounted library instead of
;;     emptying the database;
;;   - the wiring: the two timers exist, the Icecast logs are rotated
;;     (nothing else knows those files exist), the playlists directory
;;     the Shepherd does not create is created, and nginx proxies the
;;     stream without buffering it.
;;
;;; Code:

(define-module (veritas unit radio-spec)
  #:use-module (veritas veritas)
  #:use-module (ice-9 rdelim)
  #:use-module (guix)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (gnu services audio)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (gnu services web)
  #:use-module (wolk-jjba nginx)
  #:use-module (wolk-jjba radio)
  #:export (spec))

(define (contains? haystack needle)
  "Return #t when NEEDLE occurs in HAYSTACK."
  (and (string-contains haystack needle) #t))

(define (read-file path)
  "Return the contents of PATH with the comment lines removed.

The guard below is about the *configuration*, so a comment that explains
what the old hard-coded passwords were must not trip it."
  (call-with-input-file path
    (lambda (port)
      (let loop ((lines '()))
        (let ((line (read-line port)))
          (if (eof-object? line)
              (string-concatenate-reverse lines)
              (loop (if (string-prefix? ";" (string-trim line))
                        lines
                        (cons (string-append line "\n") lines)))))))))

(define icecast-text
  (icecast-config-text #:source-password "source-pw"
                       #:admin-password "admin-pw"
                       #:port 6690))

(define escaped-text
  (icecast-config-text #:source-password "a&b<c>d\"e'f"
                       #:admin-password "admin-pw"))

(define mpd-configuration
  (radio-mpd-configuration #:source-password "source-pw"
                           #:admin-password "admin-pw"
                           #:read-password "read-pw"))

(define outputs (mpd-configuration-outputs mpd-configuration))

(define (output-mount output)
  (assoc-ref (mpd-output-extra-options output) 'mount))

(define (output-option output option)
  (assoc-ref (mpd-output-extra-options output) option))

(define health (radio-health-job))
(define scan (radio-scan-job))

;; The timers live in a service type, so they are read the way the
;; service compiler reads them.
(define capability (radio-capability))

(define (extension-towards type)
  (find (lambda (extension)
          (eq? (service-extension-target extension) type))
        (service-type-extensions (service-kind capability))))

(define timers ((service-extension-compute
                 (extension-towards shepherd-root-service-type))
                '()))

(define rotated-logs ((service-extension-compute
                       (extension-towards log-rotation-service-type))
                      '()))

(define (timer-named name)
  (find (lambda (timer)
          (eq? (car (shepherd-service-provision timer)) name))
        timers))

(define (start-of name)
  "The start gexp of the timer NAME, as text."
  (object->string
   (gexp->approximate-sexp (shepherd-service-start (timer-named name)))))

;; ====== The suite ======

(define radio-suite
  (suite "Radio Suite"

         (test "Icecast is configured from the secrets, at the sizes a phone needs"
               (assert-true (contains? icecast-text
                                       "<source-password>source-pw</source-password>")
                            #:name "The source password comes from the secret")
               (assert-true (contains? icecast-text
                                       "<admin-password>admin-pw</admin-password>")
                            #:name "And so does the admin password")
               (assert-true (contains? icecast-text "<burst-size>131072</burst-size>")
                            #:name "The burst is 128 KiB, not Icecast's 64 KiB default")
               (assert-true (contains? icecast-text "<queue-size>1048576</queue-size>")
                            #:name "The queue holds two bursts")
               (assert-true (contains? icecast-text "<sources>4</sources>")
                            #:name "There is room for every mount plus one")
               (assert-true (contains? icecast-text "<port>6690</port>")
                            #:name "It listens on 6690")
               (assert-true (contains? icecast-text
                                       "<alias source=\"/\" destination=\"/status.xsl\"/>")
                            #:name "/ is the status page")
               (assert-true (contains? icecast-text "@WEBROOT@")
                            #:name "The web root is a placeholder for the store path"))

         (test "Passwords are escaped before they reach the XML"
               (assert-true (contains? escaped-text
                                       "<source-password>a&amp;b&lt;c&gt;d&quot;e&apos;f</source-password>")
                            #:name "All five metacharacters are escaped")
               (assert-true (not (contains? escaped-text "a&b"))
                            #:name "Nothing raw is left behind"))

         (test "MPD pushes the same audio into three mounts"
               (assert-equal #:expect 3
                             #:got (length outputs)
                             #:name "Three streams")
               (assert-equal #:expect '("/radio.opus"
                                        "/radio-low.opus"
                                        "/radio.mp3")
                             #:got (map output-mount outputs)
                             #:name "The mounts are the documented ones")
               (assert-equal #:expect '("opus" "opus" "lame")
                             #:got (map (lambda (output)
                                          (output-option output 'encoder))
                                        outputs)
                             #:name "Two Opus and one MP3 for reach")
               (assert-equal #:expect '("128000" "64000" "96000")
                             #:got (map (lambda (output)
                                          (output-option output 'bitrate))
                                        outputs)
                             #:name "128k, 64k for mobile data, 96k MP3")
               (assert-true (every mpd-output-always-on? outputs)
                            #:name "Every output stays connected between tracks")
               (assert-true (every (lambda (output)
                                     (equal? "shout" (mpd-output-type output)))
                                   outputs)
                            #:name "Every output is an Icecast client")
               (assert-true (every (lambda (output)
                                     (equal? "source-pw"
                                             (output-option output 'password)))
                                   outputs)
                            #:name "Every output authenticates with the source password"))

         (test "MPD keeps its index on local disk, not on the mount"
               (assert-equal #:expect "/var/lib/mpd/tag_cache"
                             #:got (mpd-configuration-db-file mpd-configuration)
                             #:name "The database is local")
               (assert-equal #:expect "/var/lib/mpd/state"
                             #:got (mpd-configuration-state-file mpd-configuration)
                             #:name "So is the state file that survives a restart")
               (assert-equal #:expect "/var/lib/mpd/playlists"
                             #:got (mpd-configuration-playlist-directory
                                    mpd-configuration)
                             #:name "And the playlist directory")
               (assert-true (contains? (mpd-configuration-music-directory
                                        mpd-configuration)
                                       "/mnt/wolkenschlosslagerung/music")
                            #:name "The library is the CIFS mount")
               (assert-equal #:expect "8192"
                             #:got (assoc-ref
                                    (mpd-configuration-extra-options
                                     mpd-configuration)
                                    'audio_buffer_size)
                             #:name "Eight megabytes of decode buffer absorb slow reads"))

         (test "MPD clients must authenticate, and the two passwords differ"
               (let ((passwords (filter-map
                                 (lambda (pair)
                                   (and (eq? (car pair) 'password) (cdr pair)))
                                 (mpd-configuration-extra-options
                                  mpd-configuration))))
                 (assert-equal #:expect
                               '("admin-pw@read,add,control,admin"
                                 "read-pw@read,add,control")
                               #:got passwords
                               #:name "An admin and a read-only password")))

         (test "The health job authenticates and watches every mount"
               (assert-true (contains? health "radio.opus")
                            #:name "The main mount is checked")
               (assert-true (contains? health "radio-low.opus")
                            #:name "The mobile mount is checked")
               (assert-true (contains? health "radio.mp3")
                            #:name "The MP3 mount is checked")
               (assert-true (contains? health "exec 3<>/dev/tcp/127.0.0.1/6600")
                            #:name "MPD liveness is a TCP connect")
               (assert-true (contains? health "mountpoint -q")
                            #:name "The library mount is checked")
               (assert-true (contains? health "status %state%")
                            #:name "The player state comes from mpc's format string")
               (assert-true (contains? health "MPD_HOST=\"$mpd_password@")
                            #:name "mpc authenticates with the password from the secret")
               (assert-true (contains? health "SECRETS_DIR=/etc/secrets")
                            #:name "The secrets directory is the real one")
               (assert-true (contains? health "$SECRETS_DIR/mpd-admin")
                            #:name "The password is read at run time")
               (assert-true (not (contains? health "admin-pw"))
                            #:name "No password is baked into the job script")
               (assert-true (contains? health "stats")
                            #:name "The song count is read, for the empty-database case")
               (assert-true (contains? health "update --wait >&2")
                            #:name "An empty database is rescanned, with its output off stdout"))

         (test "A paused player is left alone, and cannot add up to a restart"
               (assert-true (contains? health "paused|stopped)")
                            #:name "The two states a listener can ask for are handled together")
               (assert-true (contains? health
                                       "MPD is $mpd_state, leaving the player alone")
                            #:name "Both are left as they are, and the log says so")
               (assert-true (contains? health "status %length%")
                            #:name "The queue length is what separates them from an empty queue")
               (assert-true (contains? health
                                       "[ \"$queued\" = \"0\" ] && [ -n \"$mpd_songs\" ] && [ \"$mpd_songs\" -gt 0 ]")
                            #:name "Only a queue with nothing in it is started")
               (assert-equal #:expect 1
                             #:got (length (filter (lambda (line)
                                                     (contains? line "play 1"))
                                                   (string-split health #\newline)))
                             #:name "There is exactly one way to start playback")
               (assert-false (contains? health "MPD is paused, starting playback")
                             #:name "A paused player is never played again"))

         (test "The queue this job builds is the only thing it starts"
               (assert-true (contains? health "MPC=\"mpc -p 6600\"")
                            #:name "The port is spliced into the script once")
               (assert-true (contains? health "$MPC add /")
                            #:name "An empty queue is filled from the library")
               (assert-true (contains? health "$MPC repeat on")
                            #:name "And looped, so the station cannot run out")
               (assert-true (contains? health "$MPC play 1")
                            #:name "And started at the top of the queue")
               (assert-true (contains? health
                                       "the queue is empty, queuing the library")
                            #:name "The repair says what it did, in the job log")
               (assert-false (contains? health "play >&2")
                             #:name "No bare play: a pause would be resumed by it")
               (assert-true (contains? health
                                       "[ \"$mpd_up\" -eq 1 ]")
                            #:name "A play is not attempted while MPD is down")
               (assert-true (contains? health
                                       "[ \"$library_mounted\" -eq 1 ] && [ \"$mpd_up\" -eq 1 ]")
                            #:name "Nor while the library is unmounted")
               (assert-true (contains? health
                                       "[ \"$was_playing\" -eq 1 ] && [ \"$library_mounted\" -eq 1 ] && [ \"$sources\" -lt \"$expected_total\" ]")
                            #:name "Missing sources only count for a player that was already playing")
               (assert-true (contains? health
                                       "[ \"$resume_attempted\" -eq 1 ] && [ \"$mpd_state\" != \"playing\" ]")
                            #:name "A play that did not take still counts, so a wedged player is restarted")
               (assert-true (< (string-contains health "$MPC play 1")
                               (string-contains health "broken=0"))
                            #:name "The start runs before the failure counter"))

         (test "The health job only intervenes after repeated failures"
               (assert-true (contains? health "consecutive")
                            #:name "Failures are counted across runs")
               (assert-true (contains? health "if [ \"$failures\" -ge 3 ]")
                            #:name "Three bad checks in a row are needed")
               (assert-true (contains? health "herd restart icecast")
                            #:name "Icecast is restarted first")
               (assert-true (< (string-contains health "herd restart icecast")
                               (string-contains health "herd restart mpd"))
                            #:name "Then MPD, which would otherwise reconnect to nothing")
               (assert-true (contains? health
                                       "if [ \"$mpd_up\" -eq 0 ] || [ \"$was_playing\" -eq 1 ]")
                            #:name "MPD is only restarted when it is down or was playing")
               (assert-true (contains? health "not restarting mpd")
                            #:name "A paused player is never bounced back into play"))

         (test "The scan job skips a library that is not there"
               (assert-true (contains? scan "mountpoint -q")
                            #:name "It asks whether the mount is up")
               (assert-true (contains? scan "skipping the scan")
                            #:name "And says so instead of scanning")
               (assert-true (contains? scan "update --wait")
                            #:name "Otherwise it refreshes the database")
               (assert-true (contains? scan "MPD_HOST=")
                            #:name "It authenticates like every other mpc call"))

         (test "Both timers are scheduled and rotated"
               (assert-equal #:expect '(radio-health mpd-scan)
                             #:got (map (lambda (timer)
                                          (car (shepherd-service-provision timer)))
                                        timers)
                             #:name "Two radio timers")
               (assert-true (contains? (start-of 'radio-health) "*/5 * * * *")
                            #:name "The health check runs every five minutes")
               (assert-true (contains? (start-of 'mpd-scan) "20 4 * * *")
                            #:name "The library scan runs nightly")
               (assert-true (and (member "/var/log/icecast/access.log"
                                         rotated-logs)
                                 #t)
                            #:name "Icecast's access log is rotated")
               (assert-true (and (member "/var/log/icecast/error.log"
                                         rotated-logs)
                                 #t)
                            #:name "Its error log is rotated too")
               (assert-true (and (member "/var/log/wolk-jjba/radio-health.log"
                                         rotated-logs)
                                 #t)
                            #:name "And the job log"))

         (test "The activation creates what the Shepherd does not"
               (let ((activation (object->string
                                  ((service-extension-compute
                                    (extension-towards activation-service-type))
                                   '()))))
                 (assert-true (contains? activation "/var/lib/mpd/playlists")
                              #:name "MPD's playlist directory")
                 (assert-true (contains? activation "/var/lib/wolk-radio")
                              #:name "The failure counter's directory")))

         (test "The service provides the Icecast account"
               (let ((accounts (object->string
                                ((service-extension-compute
                                  (extension-towards account-service-type))
                                 '()))))
                 (assert-true (contains? accounts "icecast")
                              #:name "The unprivileged user is part of the capability")))

         (test "nginx proxies the stream without buffering it"
               (let* ((locations (radio-stream-locations))
                      (radio (car locations))
                      (uri (@@ (gnu services web) nginx-location-configuration-uri))
                      (body (@@ (gnu services web) nginx-location-configuration-body))
                      (text (string-join (body radio) "\n")))
                 (assert-equal #:expect "^~ /radio/"
                               #:got (uri radio)
                               #:name "A ^~ location wins over the static-asset regex")
                 (assert-true (contains? text "proxy_buffering off;")
                              #:name "Audio is forwarded, not buffered")
                 (assert-true (contains? text "proxy_read_timeout 3600s;")
                              #:name "A stream is one request that never ends")
                 (assert-true (contains? text "proxy_http_version 1.1;")
                              #:name "The upstream speaks HTTP/1.1")
                 (assert-true (contains? text "Access-Control-Allow-Origin")
                              #:name "Web players on another origin are allowed")
                 (assert-true (contains? text "Cache-Control")
                              #:name "The stream is not cacheable")
                 (assert-true (contains? text "Strict-Transport-Security")
                              #:name "The location repeats the security headers")))

         (test "The live vhost carries the stream"
               (let* ((locations (@@ (gnu services web)
                                     nginx-server-configuration-locations))
                      (uri (@@ (gnu services web)
                               nginx-location-configuration-uri))
                      (uris (map uri (locations jointhefreeworld-nginx-conf))))
                 (assert-true (and (member "^~ /radio/" uris) #t)
                              #:name "https://jointhefreeworld.org/radio/ is served")))

         (test "No stream password is committed to the repository"
               (let ((sources (string-append
                               (read-file "src/wolk-jjba/radio.scm")
                               (read-file "config.scm"))))
                 (assert-true (not (contains? sources "hackme"))
                              #:name "The old literal passwords are gone")
                 (assert-true (contains? sources "icecast-source")
                              #:name "And the secret file is used instead")))))

(define (spec)
  (veritas-run radio-suite))
