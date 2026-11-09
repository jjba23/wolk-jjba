;;; export-docs.el --- export the manual to HTML  -*- lexical-binding: t; -*-
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; `maak docs' runs this: every page under docs/, and the README that is the
;; manual's front page, exported with the stock HTML backend.
;;
;; Each page is written beside the .org it came from, not into a separate
;; tree, because the manual's links are relative to the checkout --
;; ../src/wolk-jjba/nginx.scm, ../README.org, monitoring.org::#abuse-limits --
;; and exporting in place is what keeps every one of them working in a
;; browser.  A file: link to a .org page becomes a link to its .html, and the
;; ::# part keeps its target, because a CUSTOM_ID is the heading's id.
;;
;; Open docs/index.html when this finishes.

;;; Code:

(require 'ox-html)

;; For reading, not for publishing: no colourised source, and no "Made with
;; Emacs" footer whose validation link only answers on a public server.
(setq org-html-htmlize-output-type nil
      org-html-validation-link nil
      org-html-postamble nil)

(defvar wolk-docs-exported 0
  "How many files this run exported, so a silent no-op is visible.")

(defun wolk-docs-export (source target)
  "Export SOURCE to TARGET, and fail when TARGET was not written."
  (with-current-buffer (find-file-noselect source)
    (org-mode)
    (org-export-to-file 'html target))
  (unless (file-exists-p target)
    (error "maak docs: exporting %s wrote no %s" source target))
  (setq wolk-docs-exported (1+ wolk-docs-exported)))

(dolist (page (sort (directory-files "docs" t "\\.org\\'") #'string<))
  (wolk-docs-export page (concat (file-name-sans-extension page) ".html")))
(wolk-docs-export "README.org" "README.html")

(message "maak docs: %d files exported; open %s"
         wolk-docs-exported (expand-file-name "docs/index.html"))
