#lang racket

(require maelstrom
         maelstrom/message
         maelstrom/kv)

(define-logger counter)
(define node (make-node))

(define (node-key)
  (node-id node))

(add-handler node
             "add"
             (lambda (req)
               ; Since each node only updates its own entry, the CAS is to prevent
               ; inconsistencies if the different handler threads ran out of order.
               (let loop ()
                 (define current (kv-read seq-kv (node-key) 0))
                 (define new (+ current (message-ref req 'delta)))
                 (unless (kv-cas seq-kv (node-key) current new #:create-if-missing? #t)
                   (loop)))
               (respond req)))

(add-handler node
             "read"
             (lambda (req)
               (define all-keys (cons (node-key) (known-peers)))
               (respond req (hash 'value (apply + (map (curry kv-read seq-kv) all-keys))))))

(module+ main
  (run node))