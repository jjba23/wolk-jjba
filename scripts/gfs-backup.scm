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
