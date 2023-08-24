#lang racket
(require maelstrom
         maelstrom/message)

(define storage null)
(define storage-sema (make-semaphore 1))
(define node (make-node))

(add-handler
 node
 "broadcast"
 (lambda (req)
   (call-with-semaphore storage-sema
                        (lambda ()
                          (set! storage (cons (message-ref req 'message) storage))))
   (respond req)))

(add-handler
 node
 "read"
 (lambda (req)
   (respond
    (to req
        (hash 'messages (call-with-semaphore
                         storage-sema
                         ; make a copy of the list.
                         (lambda () (map values storage))))))))

(module+ main
  (run node))