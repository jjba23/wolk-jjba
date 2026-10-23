;;; bash.scm

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
;; The server's interactive shell, written as data.
;;
;; `home/joe.scm' assembles ~/.bashrc from four pieces, in this order:
;;
;;   bashrc-preamble     the provenance header, the machine identity and the
;;                       plain shell options (this module);
;;   shell-lib.bash      the shared prompt, git segment and helper functions,
;;                       spliced in verbatim (home/bash/shell-lib.bash);
;;   bashrc-library-data the greeting pool, the one-line git shortcuts and the
;;                       shared aliases, generated from the lists below;
;;   bashrc-postlude     this server's checkout and Shepherd helpers, its
;;                       own aliases, the optional integrations, `cc_boot'.
;;
;; So changing a greeting, a git shortcut or an alias is a one-line change to
;; a list here, never an edit to a generated file -- the same shape the
;; desktop (heks-bash) and macOS (cask-and-cons) configs use.  The greeting
;; pool is deliberately identical on all three machines; keep it that way
;; when adding one.
;;
;; Only the shared library is read from disk (it is a @file{.bash} file, not
;; Scheme data); everything else here is plain strings and lists, with no
;; (guix gexp) dependency, so the module can be loaded and tested on its own.

;;; Code:

(define-module (wolk-jjba bash)
  #:use-module (ice-9 textual-ports)
  #:export (bash-identity bash-vars
                          bash-history-vars
                          bash-prelude
                          bash-shared-aliases
                          bash-git-shortcuts
                          bash-greetings
                          bash-machine-aliases
                          bash-server-functions
                          wolk-jjba-checkout
                          serialize-bash-assignment
                          serialize-bash-var
                          serialize-bash-alias
                          serialize-bash-function
                          serialize-bash-greetings
                          shell-lib-filename
                          bashrc-preamble
                          bashrc-shared-library
                          bashrc-library-data
                          bashrc-postlude))

;; ---- machine identity -------------------------------------------------------
;; Read by the shared shell library to render the prompt and the greeting:
;;   ╭─ joe@pigeon ω guix/server ~/Hacking/wolk-jjba
;;   ╰─ main ✚3 ↑1↓2 ⚑1 ω
;; The values are emitted as plain assignments, not exports: nothing outside
;; the rc reads them.
(define bash-identity
  '(("CC_FLAVOR" . "wolk-jjba") ("CC_HOST_KIND" . "guix/server")
    ("CC_SIGIL" . "ω")
    ("CC_ACCENT" . "45")
    ("CC_RC_FILE" . "$HOME/.bashrc")))

;; Environment shared with the other two machines.  Exported, so children
;; inherit them; ${PAGER} and friends are set by the shared library.
(define bash-vars
  '(("TERM" . "xterm-256color") ("CDPATH" . ".:$HOME/Hacking:$HOME/Work")))

;; History settings.  Plain assignments, not exports: the size of the history
;; is per-shell state, and exporting it would impose this machine's 500k on
;; every bash a subprocess starts.
(define bash-history-vars
  '(("HISTSIZE" . "500000") ("HISTFILESIZE" . "100000")
    ("HISTTIMEFORMAT" . "%F %T  | ")
    ("HISTCONTROL" . "ignoreboth:erasedups")
    ("HISTIGNORE" . "&:[ ]*:exit:ls:bg:fg:history:clear:cd:pwd")))

;; Interactive shell options.  Everything here must stay harmless on a server
;; whose bash may also be run non-interactively, so nothing reads a TTY.
(define bash-prelude
  '("shopt -s histappend cmdhist checkwinsize 2> /dev/null"
    "shopt -s autocd dirspell cdspell 2> /dev/null"
    "set -o noclobber"
    "set -o emacs"
    "bind \"set completion-ignore-case on\""
    "bind \"set completion-map-case on\""
    "bind \"set show-all-if-ambiguous on\""
    "bind \"set mark-symlinked-directories on\""
    ""
    "# ble.sh is optional on a server: load it when it has been installed."
    "# shellcheck source=/dev/null"
    "[[ $- == *i* && -r ~/.local/share/blesh/ble.sh ]] &&"
    "  source -- ~/.local/share/blesh/ble.sh"))

;; ---- shared language data ---------------------------------------------------
;; Navigation, emacs, podman, fetch, ...: the set every machine shares.  The
;; shared shell library defines the functions some of these point at (hgrep,
;; cdroot), so an alias here must never be named like one of its functions.
(define bash-shared-aliases
  '((".." . "cd ..;pwd") ("..." . "cd ../..;pwd")
    ("...." . "cd ../../..;pwd")
    ("c" . "clear")
    ("h" . "history")
    ("hg" . "hgrep")
    ("tree" . "tree --dirsfirst -F")
    ("mkdir" . "mkdir -p -v")
    ("df" . "df -h")
    ("e" . "emacsclient -t")
    ("k" . "pkill")
    ("fetch" . "fastfetch")
    ("vanilla-emacs" . "emacs -Q")
    ("restart-emacs" . "pkill emacs; emacs --daemon")
    ("docker" . "podman")
    ("docker-compose" . "podman compose")
    ("find-largest-files" . "du -h -x -s -- * 2>/dev/null | sort -r -h | head -20")))

;; One-line git shortcuts, as data: (NAME . BODY).  glog is multi-line and
;; stays in shell-lib.bash next to the other functions.
(define bash-git-shortcuts
  '((gst . "git status --short --branch \"$@\";") (gd . "git diff \"$@\";")
    (gds . "git diff --stat \"$@\";")
    (gco . "git checkout \"$@\";")
    (gsw . "git switch \"$@\";")
    (gbr . "git branch -vv \"$@\";")
    (gcm . "git commit -m \"$*\";")
    (gpl . "git pull --ff-only \"$@\";")
    (gpu . "git push \"$@\";")
    (gfetch . "git fetch --all --prune \"$@\";")
    (groot . "cdroot;")))

;; The greeting pool: nerd-style sayings about free software, RMS, GNU, Emacs
;; and Linux/Unix.  Identical to heks-bash's `bash-greetings' and
;; cask-and-cons's `zsh-greetings'; a parameter so a machine can extend it.
(define bash-greetings
  (make-parameter '( ;emacs
                    

                    "Vi Vi Vi is the number of the beast. Emacs is salvation."
                    "M-x doctor. Tell me about your childhood."
                    "Evaluating buffer... Enlightenment achieved."
                    "C-x C-c. Are you sure you want to exit your entire reality?"
                    "Your .emacs file has more lines of code than most corporate startups."
                    "Emacs: The extensible, customizable, self-documenting, real-time display environment."
                    "Emacs is a magnificent operating system, it just lacks a good text editor."
                    "M-x butterfly"
                    "Escape Meta Alt Control Shift. Your pinky finger is strong."
                    "C-x C-s. Your progress is saved. Your soul is secure."
                    "Welcome to the Church of Emacs. Emacs is my editor, and GNU is its operating system."
                    "Living in the buffers since inception."
                    "C-h t. Everyone starts as a beginner."
                    "Everything is a buffer, until it's a window."
                    "M-x emacs-uptime. Reboot? Never heard of it."
                    "In Emacs, nobody can hear you C-g."
                    "Lisp: the programmable programming language."
                    "(lambda (x) x) -- the identity of a hacker."
                    ;; gnu / rms / free software
                    "GNU's Not Unix! Welcome to the recursive revolution."
                    "Free software is a matter of liberty, not price. Think free speech, not free beer."
                    "You are entering a 100% libre user space."
                    "Guile, Guix, and Glory. Welcome to the GNU system."
                    "Join us now and share the software; You'll be free, hackers, you'll be free."
                    "Happy Hacking!"
                    "There is no system but GNU, and Linux is one of its kernels."
                    "If we do not control our software, our software controls us."
                    "Proprietary software is a social problem. Keep your system clean."
                    "With digital technology, sharing is easy. Sharing is good."
                    "I'd just like to interject for a moment: what you're referring to as Linux is GNU/Linux."
                    "The four freedoms: run, study, share, improve. Number zero is the best one."
                    "Copyleft: all rights reversed."
                    "Use free software. Your freedom is not a feature request."
                    "Software wants to be free, and so do you."
                    "Treat your source like a library book: share it."
                    ;; unix / linux lore
                    "Unix is user-friendly. It's just very selective about who its friends are."
                    "In the beginning was the command line."
                    "Everything is a file, until it's a process."
                    "May the source be with you."
                    "RTFM: Read The Fine Manual."
                    "Pipe it, grep it, sed it, love it."
                    "sudo make me a sandwich."
                    "There's no place like 127.0.0.1."
                    "rm -rf: the sharpest tool in the shed."
                    "Keep calm and `man man`."
                    "Linux: because a computer should do what you tell it to."
                    "It's not a bug, it's an undocumented feature of the kernel."
                    "chmod +x your life."
                    "Talk is cheap. Show me the code.")))

;; ---- this machine's own shell code ------------------------------------------
;; Only what a server needs and the desktop does not: the checkout the machine
;; is deployed from, and one wrapper per Shepherd action that pulls that
;; checkout first and then tails the daemon's log.
(define wolk-jjba-checkout
  "/etc/byggsteg/job-clone/wolk-jjba/trunk")

(define bash-server-functions
  '((fr "cd \"$sys_config_dir\" || return" "sudo git pull" "maak fr")
    (sr "cd \"$sys_config_dir\" || return" "sudo git pull" "maak sr")
    (jr "cd \"$sys_config_dir\" || return" "sudo git pull" "maak jr")
    (wjlog "local f=\"/var/log/wolk-jjba/${1}.log\""
           "if [ -f \"$f\" ]; then"
           "\tsudo tail -f \"$f\""
           "else"
           "\tsudo tail -f /var/log/messages"
           "fi")
    (ht "sudo herd trigger \"${1}\"" "wjlog \"${1}\"")
    (hr "sudo herd restart \"${1}\"" "wjlog \"${1}\"")))

;; Aliases that differ from the shared set only because of the filesystem they
;; run on: gls does not exist here, and the server has no la alias.
(define bash-machine-aliases
  '(("ll" . "ls -lAh --group-directories-first")
    ("l" . "ls -lAh --group-directories-first")))

;; ---- serializers ------------------------------------------------------------
;; One function per shape, so every generated line looks the same however it
;; was declared.  Nothing here quotes for a shell: the bodies are Scheme data
;; that the author writes with the quoting the shell needs.

(define (serialize-bash-assignment pair)
  "Serialize @var{pair}, a @code{(NAME . VALUE)} pair, as a plain assignment.

Unlike @code{serialize-bash-var} nothing is exported: the @code{CC_*}
variables are only read by the shared shell library."
  (format #f "~a=\"~a\""
          (car pair)
          (cdr pair)))

(define (serialize-bash-var pair)
  "Serialize @var{pair} as an exported shell variable."
  (format #f "export ~a=\"~a\"\n"
          (car pair)
          (cdr pair)))

(define (serialize-bash-alias pair)
  "Serialize @var{pair} as a shell alias."
  (format #f "alias ~a=\"~a\"\n"
          (car pair)
          (cdr pair)))

(define (serialize-bash-function function)
  "Serialize @var{function}, a @code{(NAME . BODY)} pair, as a shell function.

@var{BODY} is either one line or a list of lines; a list is indented one tab
per line, and a line that starts with a tab keeps its own extra indent (that
is how nested blocks stay readable in the generated file)."
  (format #f "~a () {\n\t~a\n}\n\n"
          (car function)
          (if (list? (cdr function))
              (string-join (cdr function) "\n\t")
              (cdr function))))

(define (shell-double-quote text)
  "Return @var{text} escaped for use inside a double-quoted shell string.

A greeting is prose: it may carry a quote, a dollar sign or a backtick, and
each of those must survive into the generated array literally.  The argument
is not called `string': it would shadow the procedure used to rebuild each
character."
  (string-concatenate (map (lambda (char)
                             (if (memv char
                                       (list #\\ #\" #\$ #\`))
                                 (string #\\ char)
                                 (string char)))
                           (string->list text))))

(define (serialize-bash-greetings)
  "Return the greeting pool as the @code{CC_GREETINGS} bash array.

An empty pool would make @code{shell-greeting} index an empty array, which in
bash is not an error but a silently empty greeting, so the pool is expected to
stay non-empty; the unit tests check that it does."
  (string-append "CC_GREETINGS=(\n"
                 (string-join (map (lambda (greeting)
                                     (format #f "\t\"~a\""
                                             (shell-double-quote greeting)))
                                   (bash-greetings)) "\n") "\n)\n"))

;; ---- the shared library -----------------------------------------------------
(define shell-lib-filename
  (make-parameter "shell-lib.bash"))

(define (read-source-file file-name)
  "Return the contents of @var{file-name}, a file of this repository.

Look next to this module first, then at the two repository-relative places it
can be: the module's own directory, and @file{home/bash} where
@file{shell-lib.bash} lives.  The fallbacks carry the case of compiled code,
whose @code{current-filename} points into the cache."
  (let loop
    ((paths (list (and (current-filename)
                       (format #f "~a/~a"
                               (dirname (current-filename)) file-name))
                  (format #f "src/wolk-jjba/~a" file-name)
                  (format #f "home/bash/~a" file-name))))
    (cond
      ((null? paths)
       (error "wolk-jjba: cannot find the shared shell file" file-name))
      ((and (car paths)
            (file-exists? (car paths)))
       (call-with-input-file (car paths)
         get-string-all))
      (else (loop (cdr paths))))))

(define (bashrc-shared-library)
  "Return the shared shell library as text, ready to splice into the rc.

It goes to @code{mixed-text-file} as a string, never as a file-like object:
that procedure substitutes the *store path* of a file-like object, which would
put a @file{/gnu/store/...} line in the middle of the rc instead of the
library."
  (read-source-file (shell-lib-filename)))

;; ---- the generated rc -------------------------------------------------------
;; `home/joe.scm' concatenates these four pieces, and each ends with the newline
;; the next one needs: the text below wrapped around the library read above.

(define (bashrc-preamble)
  "Return the header, identity, variables and shell options of the rc."
  (string-append (string-join '("# shellcheck shell=bash"
                                "# shellcheck disable=SC2034  # palette values are consumed indirectly (${!name})"
                                "# bashrc.sh - Bash configuration for wolk-jjba"
                                ""
                                "# The server half of one shell experience shared with heks-bash"
                                "# (Guix desktop) and cask-and-cons (macOS). The two-line prompt, the"
                                "# palette, the git segment, the helper functions and the greeting are"
                                "# identical; only the identity and the server-specific helpers differ."
                                ""
                                "# Generated by Guix Home. Do not edit the file in ~/.bashrc: change"
                                "# the sources and run `maak jr'. The sources are"
                                "#   src/wolk-jjba/bash.scm        identity, language data, helpers"
                                "#   home/bash/shell-lib.bash      shared prompt, git segment, helpers"
                                "#   home/bash/lesskey             pager keymap (~/.config/lesskey)"
                                ""
                                "# ./bash/lesskey is the shared pager keymap (Emacs keys for less);"
                                "# Guix Home installs it as ~/.config/lesskey, where less(1) looks for it."
                                ""
                                "# Code:"
                                ""
                                "# ---- machine identity (read by the shared shell library) ----"
                                "") "\n")
   (string-join (map serialize-bash-assignment bash-identity) "\n")
   "

# ---- shell basics (same values as the other two machines) ----
"
   (string-concatenate (map serialize-bash-var bash-vars))
   (string-join (map serialize-bash-assignment bash-history-vars) "\n")
   "\n\n"
   (string-join bash-prelude "\n")
   "\n\n"))

(define (bashrc-library-data)
  "Return the greeting array, the one-line git shortcuts and the aliases.

The pool must be emitted before @code{cc_boot} runs, because
@code{shell-greeting} indexes it; the shortcuts and aliases come after the
shared library so a definition here wins."
  (string-append
   "
# ---- greeting (data: bash-greetings in src/wolk-jjba/bash.scm) ----
"
   (serialize-bash-greetings)
   "
# ---- git shortcuts (data: bash-git-shortcuts in src/wolk-jjba/bash.scm) ----
"
   (string-concatenate (map serialize-bash-function bash-git-shortcuts))
   "
# ---- aliases (data: bash-shared-aliases in src/wolk-jjba/bash.scm) ----
"
   (string-concatenate (map serialize-bash-alias bash-shared-aliases))
   "\n"))

(define (bashrc-postlude)
  "Return this machine's helpers, aliases, integrations and the boot call."
  (string-append "# ---- wolk-jjba: checkout + Shepherd helpers ----
"
   "# Each helper pulls the checkout, then runs the matching maak task;
"
   "# wjlog tails a daemon's own log, falling back to the system log.
"
   (format #f "sys_config_dir=\"~a\"\n\n" wolk-jjba-checkout)
   (string-concatenate (map serialize-bash-function bash-server-functions))
   "# ---- wolk-jjba: aliases ---------------------------------------------
"
   (string-concatenate (map serialize-bash-alias bash-machine-aliases))
   "
# ---- integrations ---------------------------------------------------
"
   (string-join '("command -v fzf > /dev/null 2>&1 && eval \"$(fzf --bash)\""
                  "[[ -r /run/current-system/profile/etc/profile.d/nix.sh ]] &&"
                  "    . /run/current-system/profile/etc/profile.d/nix.sh"
                  "command -v direnv > /dev/null 2>&1 && eval \"$(direnv hook bash)\""
                  "[[ -n ${GUIX_PROFILE:-} && -r $GUIX_PROFILE/etc/profile ]] &&"
                  "    . \"$GUIX_PROFILE/etc/profile\"") "\n")
   "

# ---- boot: colours, prompt hook, greeting ---------------------------
"
   "cc_boot\n"))
