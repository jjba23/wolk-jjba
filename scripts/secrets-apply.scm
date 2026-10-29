;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Command-line wrapper for (wolk-jjba secrets), the by-hand half of the
;; secrets-apply job.  All the policy lives in the module, where
;; test/veritas/unit/secrets-spec.scm can run it against fixture
;; directories; this file only hands it the command line, so
;; `maak secrets' -- and the Shepherd timer, which runs the same module
;; as a program-file -- write exactly the same bytes.
;;
;;   guile -L ./src ./scripts/secrets-apply.scm                 # dry run
;;   guile -L ./src ./scripts/secrets-apply.scm --apply --user joe \
;;                                              --user byggsteg-runner
;;
;; On the machine the timer runs it with --apply as root, because the
;; file it derives belongs to an account that is not root's.  From the
;; machine that holds the encrypted copies, `maak secrets' does the same
;; over ssh.
;;
;; Code:

(use-modules (ice-9 format)
             (wolk-jjba secrets))

(exit (main))
