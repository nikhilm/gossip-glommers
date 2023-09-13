#lang racket

(require maelstrom
         maelstrom/message)

(define-logger counter)

(define (kv-operation msg)
  (define ch (make-channel))
  (rpc "seq-kv" msg (lambda (resp)
                      #;(log-counter-debug "got response ~v" resp )
                      (channel-put ch resp)))
  #;(log-counter-debug "Waiting for rpc response on kv-op ~v" msg)
  (channel-get ch))

(define (kv-read k [default 0])
  (define resp (kv-operation (make-message (hash 'type "read"
                                                 'key k))))
  #;(log-counter-debug "read ~v result ~v" k resp)
  (case (message-type resp)
    [("error") default]
    [("read_ok") (message-ref resp 'value)]
    [else (error 'kv-read "Unexpected respose type ~v" (message-type resp))]))

(define (kv-write k v)
  (define resp (kv-operation (make-message (hash 'type "write"
                                                 'key k
                                                 'value v))))
  (when (not (equal? "write_ok" (message-type resp)))
    (error 'kv-write "Unexpected response ~v" resp))
  #;(log-counter-debug "write ~v ~v ok" k v))

(define (kv-cas k from to #:create-if-missing? [create-if-missing #f])
  (define resp (kv-operation (make-message (hash 'type "cas"
                                                 'key k
                                                 'from from
                                                 'to to
                                                 'create_if_not_exists create-if-missing))))
  (case (message-type resp)
    [("cas_ok") #t]
    [("error") (case (message-ref resp 'code)
                 [(22) (begin
                         (log-counter-debug "CAS did not succeed ~v ~v ~v because: ~v" k from to (message-ref resp 'text))
                         #f)]
                 [(20) (error 'kv-cas "~v: ~v" k (message-ref resp 'text))])]
    [else (error 'kv-cas "Unexpected response type ~v" (message-type resp))]))

(define node (make-node))

(define (node-key)
  (node-id node))

(add-handler node
             "add"
             (lambda (req)
               ; Since each node only updates its own entry, the CAS is to prevent
               ; inconsistencies if the different handler threads ran out of order.
               (let loop ()
                 (define current (kv-read (node-key)))
                 (define new (+ current (message-ref req 'delta)))
                 (unless (kv-cas (node-key) current new #:create-if-missing? #t)
                   (loop)))
               (respond req)))

(add-handler node
             "read"
             (lambda (req)
               (define all-keys (cons (node-key) (known-peers)))
               (respond req (hash 'value (apply + (map kv-read all-keys))))))

(module+ main
  (run node))