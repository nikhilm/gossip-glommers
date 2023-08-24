#lang racket
(require maelstrom)
(require maelstrom/message)

(define-logger broadcast)
(define node (make-node))
(define peers (box null))

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
   (respond req)
   
   (define value (message-ref req 'message))
   (define sender (message-sender req))
   
   (define ch (make-channel))
   (thread-send state-thread (Add ch value))
   (define updated (channel-get ch))
   
   (when updated
     (define unacked (list->mutable-set
                      (for/list ([peer (in-list (unbox peers))]
                                 #:when (not (equal? peer sender)))
                        peer)))
     ; This impl, when used in 3d (25 nodes and added latency)
     ; does not yet perform as well as required.
     ; Too many broadcast messages are sent per op, and max latencies are higher.
     (let loop ([i 1])
       (log-broadcast-debug "Unacked peers for ~v are ~v~n" value unacked)
       (unless (set-empty? unacked)
         (for ([peer (in-set unacked)])
           (rpc peer (make-message
                      (hash 'message value
                            'type "broadcast"))
                (lambda (response)
                  ; TODO assert response is actually broadcast_ok.
                  (log-broadcast-debug "val: ~v iter: ~v: Got a response from ~v~n" value i (message-sender response))
                  (set-remove! unacked (message-sender response)))))
         (sleep 0.1)
         (loop (add1 i)))))))

(add-handler
 node
 "read"
 (lambda (req)
   (log-broadcast-debug "~v read request" (current-inexact-monotonic-milliseconds))
   (define ch (make-channel))
   (thread-send state-thread (Get ch))
   (respond req
            (hash 'messages (channel-get ch)))))

(add-handler
 node
 "topology"
 (lambda (req)
   (respond req)
               
   ; Exit the process on failure to avoid incorrect behavior.       
   (with-handlers
       ([exn:fail?
         (λ (e)
           (log-broadcast-error "Error reading topology. Exiting! Error was: ~v" e)
           (exit 1))])
                 
     (define the-peers (hash-ref (message-ref req 'topology)
                                 (string->symbol (node-id node))))
     ; try updating the peer list 5 times to deal with potential spurious failures.
     ; for/or stops the first time the body is #t, and returns #f otherwise.
     ; box-cas! returns #t when the swap succeeds.
     (unless (for/or ([_ (in-range 5)])
               (box-cas! peers null the-peers))
       (error 'topology-handler "unable to box-cas! peers list after several attempts"))
     (log-broadcast-debug "my peers are ~v" the-peers))))

(module+ main (run node))