#lang racket/base

(require maelstrom
         maelstrom/message)

(provide seq-kv
         lin-kv
         kv-read
         kv-write
         kv-cas)

(struct kv (id))
(define seq-kv (kv "seq-kv"))
(define lin-kv (kv "lin-kv"))

(define-logger kv)

(define (kv-operation kv msg)
  (define ch (make-channel))
  (rpc (kv-id kv) msg (lambda (resp)
                        (log-kv-debug "kv-operation ~v: got response ~v" msg resp)
                        (channel-put ch resp)))
  (log-kv-debug "Waiting for rpc response on kv-op ~v" msg)
  (channel-get ch))

(define (kv-read kv k default)
  (define resp (kv-operation kv (make-message (hash 'type "read"
                                                    'key k))))
  (case (message-type resp)
    [("error") default]
    [("read_ok") (message-ref resp 'value)]
    [else (error 'kv-read "Unexpected respose type ~v" (message-type resp))]))

(define (kv-write kv k v)
  (define resp (kv-operation kv (make-message (hash 'type "write"
                                                    'key k
                                                    'value v))))
  (when (not (equal? "write_ok" (message-type resp)))
    (error 'kv-write "Unexpected response ~v" resp)))

(define (kv-cas kv k from to #:create-if-missing? [create-if-missing #f])
  (define resp (kv-operation kv (make-message (hash 'type "cas"
                                                    'key k
                                                    'from from
                                                    'to to
                                                    'create_if_not_exists create-if-missing))))
  (case (message-type resp)
    [("cas_ok") #t]
    [("error") (case (message-ref resp 'code)
                 [(22) (begin
                         (log-kv-warning "CAS did not succeed ~v ~v ~v because: ~v" k from to (message-ref resp 'text))
                         #f)]
                 [(20) (error 'kv-cas "~v: ~v" k (message-ref resp 'text))])]
    [else (error 'kv-cas "Unexpected response type ~v" (message-type resp))]))
