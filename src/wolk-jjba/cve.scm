;; wolk-jjba - my Lisp machine cloud server
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Commentary:
;;
;; Which published vulnerabilities affect the packages this machine runs.
;;
;; The source is CISA's Known Exploited Vulnerabilities catalogue, one
;; JSON document, no key, no rate limit, updated whenever a vulnerability
;; is confirmed to be exploited in the wild: the list of flaws that are
;; *already* being used against real hosts.  A CVE that is not in it may
;; still matter, but one that is in it and names a package installed here
;; is a reason to upgrade today.
;;
;; The matching is by *word*, not by CPE or version range: the catalogue
;; names a vendor and a product ("OpenBSD", "OpenSSH"; "Linux", "Kernel")
;; and a Guix package is named "openssh" or "linux-libre".  So both sides
;; are normalised to lower-case words and a package matches when one of
;; its words is one of the product's words.  Hyphens split, which is what
;; makes linux-libre match "Linux Kernel"; word equality -- rather than a
;; substring test -- is what stops "git" from matching "Digital Guardian".
;;
;; That is deliberately coarse, and it costs false positives: a package
;; called "node" matches every Node.js entry.  The alternative is a CPE
;; table of this host's exact versions, maintained by hand and wrong
;; after the next upgrade, and a false positive here is one e-mail that
;; says "look at CVE-2026-1234" -- while the false negative of a missing
;; match is the vulnerability nobody told you about.
;;
;; Nothing in this module touches the machine: it takes text and returns
;; matches, so the audit program that fetches the feed can be tested
;; against a fixture instead of against the internet.
;;
;; Code:

(define-module (wolk-jjba cve)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (kev-window-days
            kev-feed-url
            installed-package-names
            package-words
            kev-matches))

;; A month of catalogue additions.  The catalogue is cumulative, and a
;; flaw added last year has either been patched by the weekly upgrade or
;; is not in the pinned channels at all; what a daily e-mail has to catch
;; is the news, and a month is long enough that a week of downtime does
;; not lose an entry and short enough that the report stays readable.
(define kev-window-days 30)

(define kev-feed-url
  "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json")

;; Shortest word that may match.  Two-letter words ("dr", "id", "ip")
;; appear inside product names by accident and would match half the
;; package list.
(define minimum-word-length 3)

(define (field object key)
  "Return KEY's value from OBJECT, a decoded JSON object, or #f.

Guile's (json) reader has recorded object keys as symbols in some
releases and as strings in others, so both spellings are tried: a feed
that decodes to the other one must not silently match nothing."
  (and (list? object)
       (or (assoc-ref object key)
           (assoc-ref object (string->symbol key)))))

(define (elements value)
  "Return VALUE as a list: JSON arrays decode to vectors or lists."
  (cond ((vector? value) (vector->list value))
        ((list? value) value)
        (else '())))

(define (words text)
  "Return the lower-case words of TEXT, split on everything else.

\"Linux Kernel\" gives (\"linux\" \"kernel\") and \"linux-libre\" gives
(\"linux\" \"libre\"), which is the whole point: the hyphen is a word
break, not part of the name."
  (map string-downcase
       (string-tokenize
        (string-map (lambda (character)
                      (if (or (char-alphabetic? character)
                              (char-numeric? character))
                          character
                          #\space))
                    text))))

(define (package-words name)
  "Return the words NAME can be recognised by in a vendor product."
  (remove (lambda (word) (< (string-length word) minimum-word-length))
          (words name)))

(define (installed-package-names manifest-text)
  "Return every package name in MANIFEST-TEXT.

MANIFEST-TEXT is /run/current-system/profile/manifest: Guix writes one
`(name \"...\")' field per package of the profile, so the list of what
this machine runs is read as text and no `guix' process is needed at
audit time.  Outputs are `(output \"out\")' and are therefore not
mistaken for names."
  (let ((marker "(name \""))
    (let loop ((position 0) (names '()))
      (let ((hit (string-contains manifest-text marker position)))
        (if hit
            (let* ((start (+ hit (string-length marker)))
                   (end (string-index manifest-text #\" start)))
              (if end
                  (loop end (cons (substring manifest-text start end) names))
                  (reverse names)))
            (reverse (delete-duplicates names)))))))

(define* (kev-matches feed-text names #:key (since "1970-01-01"))
  "Return the (CVE . package) pairs in FEED-TEXT that concern NAMES.

Only catalogue entries added on or after SINCE (an ISO date, compared as
text) are considered: an older entry is either fixed by now or was never
applicable, and the alert has to be about news.  Each match is returned
once."
  (let* ((feed (json->scm (open-input-string feed-text)))
         (entries (elements (field feed "vulnerabilities")))
         (packages (map (lambda (name) (cons name (package-words name)))
                        (delete-duplicates names))))
    (delete-duplicates
     (append-map
      (lambda (entry)
        (let ((cve (field entry "cveID"))
              (added (field entry "dateAdded"))
              (product (string-append (or (field entry "vendorProject") "")
                                      " "
                                      (or (field entry "product") ""))))
          (if (and (string? cve)
                   (string? added)
                   (string>=? added since))
              (let ((product-words (package-words product)))
                (filter-map (lambda (package)
                              (and (any (lambda (word)
                                          (member word product-words))
                                        (cdr package))
                                   (cons cve (car package))))
                            packages))
              '())))
      entries))))
