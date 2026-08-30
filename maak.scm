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

(define-module (maak)
  #:declarative? #t
  #:use-module (maak maak))

(define (default)
  "Default task to run, call program's help."
  (list-tasks))

(define (repl)
  "Development REPL."
  (time-machine-manifest-shell '("guile -L ./src"
                                 "-c '((@ (ares server) run-nrepl-server))'")))

(define (gfs-backup)
  "Clean backups archive using GFS (grandfather-father-son) strategy."
  (time-machine-manifest-shell '("guile -L ./src ./scripts/gfs-backup.scm")))

(define has-formatted-already?
  #f)
(define (fmt)
  "Format Scheme source code files according to the Guix style guide."
  (unless has-formatted-already?
    ($ '("find . -maxdepth 8 -name '*.scm'"
         "-type f -exec guix style -f {} \\;")
       #:verbose? #t)
    (set! has-formatted-already? #t)))

(define (full-gc)
  "Performs a full garbage collection across Guix and Nix stores."
  ($ '("guix home delete-generations"))
  ($ '("sudo guix system delete-generations"))
  ($ '("sudo guix gc"))
  ($ '("nix-store --gc")))

(define (system-reconfigure)
  "Pull updates, provision web directories, and reconfigure the Guix System."
  ($ '("sudo git fetch --all || true"))
  ($ '("sudo git pull || true"))
  ($ '("sudo mkdir -p /srv/http/jointhefreeworld.org"))
  ($ '("sudo mkdir -p /srv/http/carvoeirowaterfun.com"))
  ($ '("sudo mkdir -p /srv/http"))
  ($ '("echo \"Hello World! (from wolk-jjba)\" | sudo tee /srv/http/index.html"))
  ($ '("sudo guix system reconfigure -L ./src config.scm --fallback"))
  ($ '("sudo herd restart mcron")))

(define (joe-reconfigure)
  "Pull updates and reconfigure the Guix Home environment for user 'joe'."
  ($ '("sudo git fetch --all || true"))
  ($ '("sudo git pull || true"))
  ($ '("guix home reconfigure -L ./src home/joe.scm --fallback")))

(define (full-rebuild)
  "Orchestrate a sequential rebuild of both Guix System and Guix Home profiles."
  (system-reconfigure)
  (joe-reconfigure))

(define (sr)
  "Alias for system-reconfigure."
  (system-reconfigure))

(define (jr)
  "Alias for joe-reconfigure."
  (joe-reconfigure))

(define (fr)
  "Alias for full-rebuild."
  (full-rebuild))
