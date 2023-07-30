#lang racket
(require maelstrom)
(require maelstrom/message)

(define-logger broadcast)
(define node (make-std-node))

(struct Add (resp-ch value))
(struct Get (resp-ch))
(define state-thread
  (thread
   (lambda ()
     (let loop ([storage (hash)])
       (match (thread-receive)
         [(Add resp-ch value) (define is-new (not (hash-has-key? storage value)))
                              (channel-put resp-ch is-new)
                              (loop (if is-new
                                        (hash-set storage value #t)
                                        (loop storage)))]

         [(Get resp-ch) (channel-put resp-ch (hash-keys storage))
                        (loop storage)])))))

(add-handler
 node
 "broadcast"
 (lambda (req)
   (respond (make-response req))
   
   (define value (message-ref req 'message))
   (define sender (message-sender req))
   
   (define ch (make-channel))
   (thread-send state-thread (Add ch value))
   (define updated (channel-get ch))
   
   (when updated
     (for ([peer (in-list (known-node-ids))]
           #:when (not (equal? peer sender)))
       (send peer
             (make-message
              (hash 'message value
                    'type "broadcast")))))
   ))

(add-handler
 node
 "read"
 (lambda (req)
   (log-broadcast-debug "~v read request" (current-inexact-monotonic-milliseconds))
   (define ch (make-channel))
   (thread-send state-thread (Get ch))
   (respond
    (make-response req
                   `(messages . ,(channel-get ch))))))

; TODO: use the actual topology
(add-handler
 node
 "topology"
 (lambda (req)
   ; Nothing to be done for now.
   (respond (make-response req))))

(module+ main (run node))