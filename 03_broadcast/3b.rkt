#lang racket
(require maelstrom)
(require maelstrom/message)

;; This implementation uses the following gossip protocol, which is neither efficient,
;; nor resistant to network partitions, but works for this problem.
;;
;; When a node receives a new value via the "broadcast" message, it sends it to all
;; other nodes that are known. The original sender is not sent the message to avoid
;; unbounded recursion.
;; However this condition does not protect from second degree sends -- n1 sends to n2,
;; n2 sends to n3 and then n3 sends back to n1.
;; So, when a value that is already known is received, no outgoing broadcasts are sent.
;; The expectation is that, in the absence of network partitions and assuming liveness,
;; and assuming co-operative clients that do not send the same value multiple times,
;; receiving the same value again means that at least one other node in the network is
;; aware of this value and, if it hadn't received it before, will send it to others.
;; Otherwise, everyone already knows about the value.

(define-logger broadcast)

(define storage null)
(define storage-sema (make-semaphore 1))
(define node (make-node))

(add-handler
 node
 "broadcast"
 (lambda (req)
   (define value (message-ref req 'message))
   (define updated
     (call-with-semaphore
      storage-sema
      (lambda ()
        (if (member value storage)
            #f
            (begin
              (set! storage (cons value storage))
              (log-broadcast-debug "~v Update known values ~v" (current-inexact-monotonic-milliseconds) storage)
              #t)))))
   (respond (make-response req))
   (when updated
     (for ([peer (in-list (known-node-ids))]
           #:when (not (equal? peer (message-sender req))))
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
   (define response (call-with-semaphore
                     storage-sema
                     ; make a copy of the list.
                     (lambda () (map values storage))))
   (respond
    (make-response req
                   `(messages . ,response)))))

(add-handler
 node
 "topology"
 (lambda (req)
   ; Nothing to be done for now.
   (respond (make-response req))))

(module+ main
  (require profile)
  (require profile/render-text)

  (define stderr-renderer
    (lambda (profile-data order)
      (parameterize ([current-output-port (current-error-port)])
        (render profile-data order))))
  
  (profile-thunk
   (lambda () (with-handlers ([exn:break? (lambda (x) void)]) (run node)))
   #:threads #t
   #:periodic-renderer (list 15.0 stderr-renderer)
   #:render stderr-renderer))