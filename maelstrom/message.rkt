#lang racket/base

(provide message?
         message-body
         message-ref
         message-sender
         message-id
         message-type
         make-message)

(require racket/contract)

(define (message? msg)
  (and (hash? msg)
       (hash-has-key? msg 'src)
       (hash-has-key? msg 'dest)
       (hash-has-key? msg 'body)))

(define (message-ref msg key)
  (hash-ref (message-body msg) key))

(define (message-sender msg)
  (hash-ref msg 'src))

(define (message-id msg)
  (message-ref msg 'msg_id))

(define (message-body msg)
  (hash-ref msg 'body))

(define/contract (message-type msg)
  (-> message? string?)
  (message-ref msg 'type))

(define/contract (make-message body)
  (hash? . -> . hash?)
  (hash 'body body))

(module+ test
  (require json)
  (require rackunit)
  
  (test-case
   "message validation"
   (check-false (message? "not-a-jsexpr"))
   (check-false (message? (string->jsexpr #<<EOF
{"src": "bazqux", "body": {}}
EOF
                                          )))
   (check-true (message? (string->jsexpr #<<EOF
{
  "src": "c1",
  "dest": "n1",
  "body": {
    "type": "echo",
    "msg_id": 1,
    "echo": "Please echo 35"
  }
}

EOF
                                         )))))