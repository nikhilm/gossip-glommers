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
   (respond (make-response req))))

(add-handler
 node
 "read"
 (lambda (req)
   (respond
    (make-response req
                   `(messages . ,(call-with-semaphore
                                                    storage-sema
                                                    ; make a copy of the list.
                                                    (lambda () (map values storage))))))))

(add-handler
 node
 "topology"
 (lambda (req)
   ; Nothing to be done for now.
   (respond (make-response req))))

(module+ main
  (run node))