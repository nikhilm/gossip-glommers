#lang racket
(require maelstrom
         maelstrom/message)

(define node (make-node))
(add-handler node
             "echo"
             (lambda (req)
               (respond req (hash 'echo (message-ref req 'echo))))) 

(module+ main
  (run node))