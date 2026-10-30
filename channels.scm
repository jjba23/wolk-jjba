;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; The channel list this server pins: `maak guix-pull' runs
;; `guix pull --channels=channels.scm', and the Scheme tasks run in
;; `guix time-machine --channels=channels.scm' shells.
;;
;; Guix itself is pinned to a commit, and so is the jointhefreeworld
;; channel; it carries the latest release of the collection the system
;; runs: maak (the task runner every service is started through), veritas
;; (the test suite), and the Guile libraries they share.  It comes after
;; guix in the list, so its packages take precedence over the copies Guix
;; carries, which is the point: the server gets the newest release instead
;; of whatever the last Guix import happened to pick up.
;;
;; Both are pinned to a commit rather than left to follow a branch, and the
;; channel is the reason: `guix time-machine' authenticates every commit it
;; checks out, so a channel that follows `trunk' breaks the moment trunk's
;; tip is not signed.  That is not hypothetical -- two commits pushed to
;; trunk through a web interface (README.org edits, no signature) made every
;; `maak test' and every reconfigure stop with
;;
;;   guix time-machine: error: commit 913fb4b872c397f5bc97744dad6a81a790ed1ad7
;;   lacks a signature
;;
;; before a single test ran, and CI reported it as a failed test suite.  A
;; commit moves only when this file moves, which is the point of pinning it:
;; bump it with `maak guix-pull' after a release, and the failure -- if the
;; new commit is unsigned -- is one this repository can see and fix, rather
;; than one that arrives from trunk on its own.  The commit below is the
;; channel's move to the MIT licence, which this repository made in the same
;; breath.  The `branch' is kept next to it because that is what guix records
;; for the channel and what a future bump fetches.
;;
;; The channel is pulled from GitHub, which is the copy every commit above
;; was signed for.  The introduction is the channel's first signed commit and
;; the key in its .guix-authorizations; `guix git authenticate' in the
;; channel checkout verifies the whole history against it.
;;
;;; Code:

(list (channel
        (name 'guix)
        (url "https://codeberg.org/guix/guix.git")
        (branch "master")
        (commit "d8a8dd840a94b90ad90b3a1ad903a6befe643326")
        (introduction
         (make-channel-introduction "9edb3f66fd807b096b48283debdcddccfea34bad"
          (openpgp-fingerprint
           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
        (name 'jointhefreeworld)
        (url "https://github.com/jjba23/guix-jointhefreeworld")
        (branch "trunk")
        (commit "cd2d7ca9e687c9fedd78360f80a79bfc401a1a8f")
        (introduction
         (make-channel-introduction
          "b0ac3f05075d7959860fc9e1db5871acddea3986"
          (openpgp-fingerprint
           "83BC 6E1C 8726 B8C2 97F8  D16E 24F4 6738 CE11 4AF6")))))
