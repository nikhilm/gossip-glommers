#lang info
(define collection "maelstrom")
(define deps '("base"))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))
(define scribblings '(("scribblings/maelstrom.scrbl" ())))
(define pkg-desc "A wrapper around the Maelstrom distributed systems educational framework")
(define version "0.1")
(define pkg-authors '(racket-packages@me.nikhilism.com))
(define license 'Apache-2.0)
