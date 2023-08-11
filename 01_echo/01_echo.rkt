#lang racket
(require maelstrom
         maelstrom/message)

(module+ main
  (define node (make-node))
  (add-handler node
               "echo"
               (lambda (req)
                 (respond (make-response req `(echo . ,(message-ref req 'echo))))))
  (run node))