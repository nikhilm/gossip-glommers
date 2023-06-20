#lang racket
(require maelstrom)

(module+ main
  (define node (make-node))
  (add-handler node "echo" (lambda (req)
                            (send node respond `(echo . ,(hash-ref req 'echo)))))
  (send node run))