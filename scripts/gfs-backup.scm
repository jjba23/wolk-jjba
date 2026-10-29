;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Command-line wrapper for (wolk-jjba gfs).  All the policy lives in
;; the module, where test/veritas/unit/gfs-spec.scm can run it against an
;; in-memory Storage Box; this file only hands it the command line, so
;; `maak gfs-backup' and the Shepherd timer run exactly the same code.
;;
;;   guile -L ./src ./scripts/gfs-backup.scm            # dry run
;;   guile -L ./src ./scripts/gfs-backup.scm --apply     # do it
;;
;; Code:

(use-modules (ice-9 format)
             (wolk-jjba gfs))

(exit (main))
