;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; Unit tests for (wolk-jjba bash): the data lists, their serializers, and the
;; three strings home/joe.scm wraps around home/bash/shell-lib.bash.
;;
;; Two invariants are worth a test rather than a comment.  An alias must not
;; shadow a function: bash resolves the alias first, so `alias gst=...' next to
;; `gst () { ... }' silently replaces the function (the shared library defines
;; hgrep and cdroot, which two aliases call).  And the greeting pool must stay
;; non-empty and escaped: shell-greeting indexes the array, and a plain `"'
;; inside a saying would end the string early and break every new shell.
;;
;; The shared library itself is checked as a file, because that is how
;; home/joe.scm consumes it: it must still define the functions the data calls,
;; and it must no longer carry the blocks that moved to Scheme here.

;;; Code:

(define-module (veritas unit bash-spec)
  #:use-module (veritas veritas)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (wolk-jjba bash)
  #:export (spec))

(define (serialize-all functions)
  "Return FUNCTIONS serialized exactly as the rc carries them."
  (string-concatenate (map serialize-bash-function functions)))

(define (contains? haystack needle)
  "Return @code{#t} when NEEDLE occurs in HAYSTACK."
  (and (string-contains haystack needle) #t))

(define (count-occurrences haystack needle)
  "Return how many times NEEDLE occurs in HAYSTACK.

@code{string-count} takes a character or a predicate, not a substring, so a
text needle is counted by hand."
  (let loop
    ((start 0)
     (count 0))
    (let ((at (string-contains haystack needle start)))
      (if at
          (loop (+ at
                   (string-length needle))
                (+ count 1)) count))))

(define shared-file
  "home/bash/shell-lib.bash")

;; The shared prompt and helper library, as home/joe.scm splices it in.
(define shared-library
  (call-with-input-file shared-file
    get-string-all))

(define preamble
  (bashrc-preamble))
(define library-data
  (bashrc-library-data))
(define postlude
  (bashrc-postlude))

;; Aliases are (string . string) pairs, functions are (symbol . body) pairs, so
;; the names are normalised to strings before the two sets are compared.
(define (alias-names aliases)
  (map car aliases))

(define (function-names functions)
  (map (lambda (function)
         (symbol->string (car function))) functions))

(define bash-suite
  (suite "Bash Configuration Suite"

         (test "The prompt says which machine this is"
               (assert-true (contains? preamble "CC_FLAVOR=\"wolk-jjba\"")
                            #:name "The flavour is the repository name")
               (assert-true (contains? preamble "CC_HOST_KIND=\"guix/server\"")
                            #:name "The badge says this is a Guix server")
               (assert-true (contains? preamble "CC_SIGIL=\"ω\"")
                            #:name "The sigil is the server's omega")
               (assert-true (contains? preamble "CC_ACCENT=\"45\"")
                            #:name "The accent is the server's teal")
               (assert-false (contains? preamble "export CC_FLAVOR")
                #:name "Identity is an assignment, not exported to children"))

         (test "Every machine-identity variable is emitted"
               (assert-equal #:expect 5
                             #:got (length bash-identity)
                             #:name "The five CC_* values are declared")
               (assert-equal #:expect '()
                             #:got (remove (lambda (pair)
                                             (contains? preamble
                                                        (serialize-bash-assignment
                                                         pair))) bash-identity)
                             #:name "Each one reaches the rc verbatim"))

         (test "History stays shell-local"
               (assert-true (contains? preamble
                             "export CDPATH=\".:$HOME/Hacking:$HOME/Work\"")
                            #:name "CDPATH is exported for child shells")
               (assert-true (contains? preamble "HISTSIZE=\"500000\"")
                            #:name "The history size is set")
               (assert-false (contains? preamble "export HISTSIZE")
                #:name "The history size is not pushed into every subprocess"))

         (test "The greeting pool is non-empty and unique"
               (assert-true (> (length (bash-greetings)) 0)
                            #:name "shell-greeting must always find a saying")
               (assert-equal #:expect (length (bash-greetings))
                             #:got (length (delete-duplicates (bash-greetings)))
                             #:name "No saying is declared twice"))

         (test "Greetings survive quotes, dollars and backticks"
               (parameterize ((bash-greetings (list
                                               "a \"quoted\" $HOME `date` \\ end")))
                 (assert-equal #:expect
                               "CC_GREETINGS=(
	\"a \\\"quoted\\\" \\$HOME \\`date\\` \\\\ end\"
)
"
                               #:got (serialize-bash-greetings)
                               #:name
                               "Every shell-special character is escaped")))

         (test "Every shared alias reaches the rc"
               ;; The aliases moved out of the shared library, so nothing else
               ;; would define them: a missing block here silently costs the
               ;; whole `..', `hg', `fetch' set.
               (assert-equal #:expect '()
                             #:got (remove (lambda (alias)
                                             (contains? library-data
                                                        (serialize-bash-alias
                                                         alias)))
                                           bash-shared-aliases)
                             #:name "Each shared alias is emitted verbatim")
               (assert-true (contains? library-data "alias hg=\"hgrep\"")
                            #:name "hg still points at hgrep")
               (assert-true (contains? library-data
                                       "alias ...=\"cd ../..;pwd\"")
                            #:name "the multi-character alias keeps its body"))

         (test "The greeting array is emitted once, before it is read"
               (assert-equal #:expect 1
                             #:got (count-occurrences library-data
                                                      "CC_GREETINGS=(")
                             #:name "The array is declared in the data block")
               (assert-false (contains? shared-library "CC_GREETINGS=(")
                             #:name
                             "The shared library no longer carries the pool"))

         (test "Git shortcuts are generated as functions"
               (assert-true (contains? library-data
                                       "gst () {
	git status --short --branch \"$@\";
}")
                            #:name "gst keeps its body and its arguments")
               (assert-true (contains? library-data "groot () {\n\tcdroot;\n}")
                            #:name "groot calls the shared cdroot")
               (assert-false (contains? shared-library "gst () {")
                #:name "The one-line shortcuts are no longer in the library")
               (assert-true (contains? shared-library "glog () {")
                            #:name "The multi-line glog stays in the library"))

         (test "No alias shadows a function"
               (assert-equal #:expect '()
                             #:got (lset-intersection string=?
                                                      (alias-names
                                                       bash-shared-aliases)
                                                      (function-names
                                                       bash-git-shortcuts))
                             #:name "Shared aliases are not git shortcuts")
               (assert-equal #:expect '()
                             #:got (lset-intersection string=?
                                                      (alias-names
                                                       bash-shared-aliases)
                                                      (function-names
                                                       bash-server-functions))
                             #:name "Shared aliases are not server helpers")
               (assert-equal #:expect '()
                             #:got (lset-intersection string=?
                                                      (alias-names
                                                       bash-machine-aliases)
                                                      (function-names
                                                       bash-server-functions))
                             #:name "Machine aliases are not server helpers"))

         (test "An alias stays on one line"
               (assert-equal #:expect 0
                #:got (length (filter (lambda (alias)
                                        (string-contains (cdr alias) "\n"))
                                      (append bash-shared-aliases
                                              bash-machine-aliases)))
                #:name "A body with a newline would break the alias line"))

         (test "The shared library still defines what the data calls"
               (assert-true (contains? shared-library "cc_boot () {")
                            #:name "cc_boot is defined where the rc calls it")
               (assert-true (contains? shared-library "hgrep () {")
                            #:name "The hg alias has its hgrep")
               (assert-true (contains? shared-library "cdroot () {")
                            #:name "groot has its cdroot")
               (assert-true (contains? shared-library "shell-greeting () {")
                            #:name
                            "The greeting function reads the generated array")
               (assert-true (string-suffix? "}\n" shared-library)
                            #:name "The file ends on a line of its own"))

         (test "The shared library is spliced, not referenced"
               ;; mixed-text-file writes the store *path* of a file-like object;
               ;; the library must reach it as text or the rc would fetch a
               ;; /gnu/store/... name instead of defining cc_boot.
               (assert-equal #:expect shared-library
                             #:got (bashrc-shared-library)
                             #:name "The library is read from the checkout")
               (assert-false (contains? (bashrc-shared-library) "/gnu/store/")
                             #:name "No store path leaks into the rc")
               (assert-true (contains? (bashrc-shared-library) "cc_boot () {")
                            #:name "The spliced text is the library itself"))

         (test "Server helpers wrap the checkout and the Shepherd"
               (assert-equal #:expect 1
                             #:got (count-occurrences postlude
                                                      (format #f
                                                       "sys_config_dir=\"~a\""
                                                       wolk-jjba-checkout))
                             #:name "The checkout path is assigned once")
               (assert-true (contains? postlude
                                       "fr () {
	cd \"$sys_config_dir\" || return
	sudo git pull
	maak fr
}")
                            #:name "fr pulls the checkout, then runs maak fr")
               (assert-true (contains? postlude "ht () {
	sudo herd trigger \"${1}\"
	wjlog \"${1}\"
}")
                            #:name "ht triggers a daemon and tails its log")
               (assert-true (contains? postlude
                             "alias ll=\"ls -lAh --group-directories-first\"")
                            #:name "The machine alias uses ls, not gls"))

         (test "The rc boots exactly once, at the end"
               (assert-equal #:expect 1
                             #:got (count-occurrences postlude "cc_boot")
                             #:name "cc_boot is called once in the postlude")
               (assert-true (string-suffix? "cc_boot\n" postlude)
                            #:name
                            "Nothing runs after the prompt is installed"))

         (test "The three pieces meet at line boundaries"
               (assert-true (string-suffix? "\n" preamble)
                            #:name "The library starts on a new line")
               (assert-true (string-suffix? "\n" library-data)
                            #:name "The postlude starts on a new line")
               (assert-true (string-suffix? "\n" postlude)
                            #:name "The rc ends with a newline"))))

(define (spec)
  (veritas-run bash-suite))
