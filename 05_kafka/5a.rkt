#lang racket

(require maelstrom
         maelstrom/message)

(define-logger kafka)
(define node (make-node))

(struct Send (ch key msg))
(struct Poll (ch offsets))
(struct Commit-Offsets (ch offsets))
(struct List-Committed (ch keys))
(define manager
  (thread
   (lambda ()
     ; data is actually a 2-list of (list offset index)
     ; this way we can use a list
     ; TODO: appending at the end of a list is slow. use a gvector.
     ; you can clearly see "send" latency increase as more and more elements exist in each list.
     (struct partition (next-offset committed data) #:transparent)
     
     (let loop ([logs (hash)])
       #;(log-kafka-debug "in loop, logs is ~v" logs)
       ; TODO: Clean up the match statement into functions
       ; use a submodule
       (match (thread-receive)
         [(Send ch key msg)
          (log-kafka-debug "send: ~v ~v" key msg)
          (loop (hash-update logs key
                             (lambda (part)
                               (define offset (partition-next-offset part))
                               (channel-put ch (hash 'offset offset))
                               (partition (add1 offset) (partition-committed part) (append (partition-data part) (list (list offset msg)))))
                             (lambda () (partition 0 0 null))))]
         
         [(Poll ch offsets)
          (log-kafka-debug "poll: ~v" offsets)
          (define resp (for/hash ([(key offset) (in-hash offsets)]
                                  ; TODO: Avoid double symbol->string conversion
                                  #:when (hash-has-key? logs (symbol->string key)))
                         ; TODO: This is dumb in returning all elements past the offset. constrain to at most N.
                         (values key (dropf
                                      (partition-data (hash-ref logs (symbol->string key)))
                                      (lambda (offset-element)
                                        (< (first offset-element) offset))))))
          (channel-put ch (hash 'msgs resp))
          (loop logs)]
         
         [(Commit-Offsets ch offsets)
          (log-kafka-debug "commit-offsets: ~v" offsets)
          (define new-logs (for/fold ([logs logs])
                                     ([(key offset) (in-hash offsets)])
                             (values (hash-update logs (symbol->string key)
                                                  (lambda (part)
                                                    (partition (partition-next-offset part)
                                                               offset
                                                               (partition-data part)))))))
          ; respond
          (channel-put ch (hash))
          (loop new-logs)]
         
         [(List-Committed ch keys)
          (log-kafka-debug "list-committed: ~v" keys)
          (channel-put ch
                       (hash 'offsets
                             (for/hash ([key (in-list keys)]
                                        #:when (hash-has-key? logs key))
                               (values (string->symbol key)
                                       (partition-committed (hash-ref logs key))))))
          (loop logs)])))))

; My first macro!
(define-syntax (handler stx)
  (syntax-case stx ()
    [(_ node message manager op args ...)
     #'(add-handler node
                    message
                    (lambda (req)
                      (log-kafka-debug "Sending client is ~v" (message-sender req))
                      (define message-elements (map (curry message-ref req) (list args ...)))
                      (define ch (make-channel))
                      (thread-send manager (apply op ch message-elements))
                      (define r (channel-get ch))
                      (log-kafka-debug "~v: ~v response: ~v" (current-inexact-monotonic-milliseconds) message r)
                      (respond req r)))]))

(handler node "send" manager Send 'key 'msg)
(handler node "poll" manager Poll 'offsets)
(handler node "commit_offsets" manager Commit-Offsets 'offsets)
(handler node "list_committed_offsets" manager List-Committed 'keys)

(module+ main
  (run node))