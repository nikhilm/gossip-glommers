#lang racket
(require racket/random)
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
   (respond req)))

(add-handler
 node
 "broadcast_multi"
 (lambda (req)
   (define values (message-ref req 'values))
   (store-and-forward values)
   (respond req)))

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

     (define (not-me el)
       (define as-str (symbol->string el))
       (and (not (equal? as-str (node-id node))) as-str))
     (define all-nodes (filter-map not-me (hash-keys (message-ref req 'topology))))
     ; choose n/2+1 nodes as peers
     (define the-peers (random-sample all-nodes (+ 1 (quotient (length all-nodes) 2)) #:replacement? #f))
     (log-broadcast-debug "my peers are ~v" the-peers)
     (define interval (string->number (getenv "INTERVAL_MS")))
     (for ([peer (in-list the-peers)])
       (set! peer-threads
             (cons (spawn-minder peer interval) peer-threads))))))

(define (timer-evt ms)
  (alarm-evt (+ (current-inexact-monotonic-milliseconds) ms) #|monotonic =|# #t))

(define/contract (spawn-minder peer propagate-interval-ms)
  (string? number? . -> . thread?)
  (thread
   (lambda ()
     (define ack-channel (make-channel))
     (define (interval-from-now)
       (+ propagate-interval-ms (current-inexact-monotonic-milliseconds)))
     
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