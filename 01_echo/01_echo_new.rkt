#lang racket
(require maelstrom/alt)

(module+ main
  (define node (make-std-node))
  (add-handler node
               "echo"
               (lambda (req)
                 (respond (make-response req `(echo . ,(message-ref req 'echo))))))
  (run node))