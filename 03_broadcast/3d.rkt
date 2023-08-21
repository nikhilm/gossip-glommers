#lang racket
(require maelstrom)
(require maelstrom/message)

(define-logger broadcast)
(define node (make-node))
; list of threads minding peers
(define peer-threads null)

(struct Multi-Add (resp-ch values))
(struct Get (resp-ch))

(add-handler
 node
 "broadcast"
 (lambda (req)
   (define value (message-ref req 'message))
   (store-and-forward (list value))
   (respond (make-response req))))

(add-handler
 node
 "broadcast_multi"
 (lambda (req)
   (define values (message-ref req 'values))
   (store-and-forward values)
   (respond (make-response req))))

(define/contract (store-and-forward values)
  ((listof number?) . -> . void)
  (define ch (make-channel))
  (thread-send state-thread (Multi-Add ch values))
  (channel-get ch)
  (for ([peer-thread (in-list peer-threads)])
    (thread-send peer-thread values)))

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

(add-handler
 node
 "topology"
 (lambda (req)
   (respond (make-response req))
               
   ; Exit the process on failure to avoid incorrect behavior.       
   (with-handlers
       ([exn:fail?
         (λ (e)
           (log-broadcast-error "Error reading topology. Exiting! Error was: ~v" e)
           (exit 1))])
                 
     (define the-peers (hash-ref (message-ref req 'topology)
                                 (string->symbol (node-id node))))
     (log-broadcast-debug "my peers are ~v" the-peers)
     (for ([peer (in-list the-peers)])
       (set! peer-threads
             (cons (spawn-minder peer) peer-threads))))))

(define (timer-evt ms)
  (alarm-evt (+ (current-inexact-monotonic-milliseconds) ms) #|monotonic =|# #t))

(define/contract (spawn-minder peer)
  (string? . -> . thread?)
  (thread
   (lambda ()
     (define ack-channel (make-channel))
     (define (interval-from-now)
       (+ 250 (current-inexact-monotonic-milliseconds)))
     
     ; sadly messages is both a copy of the global messages
     ; and sent also eventually becomes a copy.
     ; see if `messages` can be shared safely.
     (let loop ([messages (set)]
                [sent (set)]
                [next-time (interval-from-now)])
       (sync
        ; either we got a new value to add to the outgoing set.
        (handle-evt (thread-receive-evt)
                    (lambda (_)
                      (define values (thread-receive))
                      (loop (set-union messages (list->set values)) sent next-time)))

        ; there was a timeout, so we should try to notify the peer again.
        ; unlike the upstream Python implementation, which waits on the rpc,
        ; this should be robust to messages being dropped.
        (handle-evt (alarm-evt next-time #|monotonic =|# #t)
                    (lambda (_)
                      (define to-send (set-subtract messages sent))
                      (when (not (set-empty? to-send))
                        (log-broadcast-debug "~v timer elapsed and have outstanding. Sending to ~v: ~v" (current-inexact-monotonic-milliseconds) peer to-send)
                        (rpc peer
                             (make-message (hash 'type "broadcast_multi"
                                                 'values (set->list to-send)))
                             (lambda (response)
                               (channel-put ack-channel to-send))))
                      (loop messages sent (interval-from-now))))
        
        ; or we got an acknowledgement from the peer.
        (handle-evt ack-channel
                    (lambda (values-acked)
                      (log-broadcast-debug "~v Got ack from ~v! ~v" (current-inexact-monotonic-milliseconds)  peer values-acked)
                      (loop messages (set-union sent values-acked) next-time))))))))

 
(define state-thread
  (thread
   (lambda ()
     (let loop ([storage (set)])
       (match (thread-receive)
         [(Multi-Add resp-ch values) (channel-put resp-ch #t)
                                     (log-broadcast-debug "~v became aware of ~v" (current-inexact-monotonic-milliseconds) values)
                                     (loop (set-union storage (list->set values)))]

         [(Get resp-ch) (channel-put resp-ch (set->list storage))
                        (loop storage)])))))

(module+ main (run node))