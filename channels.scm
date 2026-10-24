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
;; The channel list this server pins: `maak guix-pull' runs
;; `guix pull --channels=channels.scm', and the Scheme tasks run in
;; `guix time-machine --channels=channels.scm' shells.
;;
;; Guix itself is pinned to a commit.  The jointhefreeworld channel follows
;; its trunk and carries the latest release of the collection the system
;; runs: maak (the task runner every service is started through), veritas
;; (the test suite), and the Guile libraries they share.  It comes after
;; guix in the list, so its packages take precedence over the copies Guix
;; carries, which is the point: the server gets the newest release instead
;; of whatever the last Guix import happened to pick up.
;;
;; The introduction is the channel's first signed commit and the key in its
;; .guix-authorizations; `guix git authenticate' in the channel checkout
;; verifies the whole history against it.
;;
;;; Code:

(list (channel
        (name 'guix)
        (url "https://codeberg.org/guix/guix.git")
        (branch "master")
        (commit "0fb918d61609f3aadc2d8ecc212926b3bdfabb4c")
        (introduction
         (make-channel-introduction "9edb3f66fd807b096b48283debdcddccfea34bad"
          (openpgp-fingerprint
           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
        (name 'jointhefreeworld)
        (url "https://codeberg.org/jjba23/guix-jointhefreeworld")
        (branch "trunk")
        (introduction
         (make-channel-introduction
          "b0ac3f05075d7959860fc9e1db5871acddea3986"
          (openpgp-fingerprint
           "83BC 6E1C 8726 B8C2 97F8  D16E 24F4 6738 CE11 4AF6")))))
