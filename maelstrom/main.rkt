#lang racket/base

(require json)
(require racket/port)
(require racket/contract)
(require racket/class)

(module+ test
  (require rackunit))

(provide make-node
         add-handler)

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

(define/contract (with-message msg handler)
  (-> message? any/c any/c)
  (handler msg))

(define (init-from-msg msg)
  (define node-id (message-ref msg 'node_id))
  (define msg-id 5)
  msg-id)

(define (initialize)
  (with-message
      (read-json)
    (lambda (msg)
      (case (message-type msg)
        [("init") (init-from-msg msg)]))))

(define node%
  (class object%
    
    (define in-port (current-input-port))
    (define out-port (current-output-port))
    ; it would be nice to refactor the non-I/O parts into a testable smaller unit
    (define node-id #f)
    (define next-msg-id 1)
    (define handlers (make-hash))
    (define current-input #f)
    
    (super-new)

    (define/public (id)
      node-id)

    (define (gen-msg-id)
      (begin0
        next-msg-id
        (set! next-msg-id (add1 next-msg-id))))

    ; this is not the public form!
    ; the public one, when it exists, should capture some context from the message, and automatically respond to that specific message
    ; also work across concurrent threads.
    ; need a thread for writing to out-port
    (define (make-response input . additional-body)
      (define response
        (make-hash `((src . ,node-id)
                     (dest . ,(message-sender input)))))
   
      (hash-set! response 'body (make-hash
                                 (append `((type . ,(string-append (message-type input) "_ok"))
                                           (in_reply_to . ,(message-id input))
                                           (msg_id . ,(gen-msg-id)))
                                         additional-body)))
      response)

    (define/public (initialize)
      (when node-id
        (error "Already initialized"))
      ; eof is allowed because in that case calling run will not do anything.
      (define input (read-json in-port))
      (unless (eof-object? input)
        (case (message-type input)
          [("init") (begin
                      (set! node-id (message-ref input 'node_id))
                      (write-json (make-response input) out-port)
                      ; TODO Use out-port
                      (printf "~n")
                      (flush-output out-port))]
          [else (error "Expected init message")])))

    (define/public (add-handler type handler)
      ; TODO: Panic if already exists
      (hash-set! handlers type handler))

    (define (dispatch msg)
      (define type (message-type msg))
      ; TODO: start a thread and custodian
      ; calls to send or respond should get queued to the output thread
      ; the thread should capture the msg sender and id, so responding works correctly.
      ((hash-ref handlers type) (message-body msg)))

    (define/public (respond . additional-body)
      (write-json (apply make-response current-input additional-body) out-port)
      ; TODO Use out-port
      (printf "~n")
      (flush-output out-port))

    (define/public (run)
      (let loop ()
        (define input (read-json in-port))
        #;(printf "Got input ~v~n" input)
        (unless (eof-object? input)
          (unless node-id
            (error "Not initialized"))
          ; OBVIOUSLY THE WRONG WAY TO DO IT.
          (set! current-input input)
          (dispatch input)
          (loop))))))

(define (make-node)
  (define node (new node%))
  (send node initialize)
  node)

(define (add-handler node type handler)
  (send node add-handler type handler))

(module+ test
  (define INIT_MSG #<<EOF
{
  "src": "c1",
  "dest": "n1",
  "body": {
    "type":     "init",
    "msg_id":   1,
    "node_id":  "n3",
    "node_ids": ["n1", "n2", "n3"]
  }
}
EOF
    )
  
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
                                         ))))
  
  (test-case
   "Initialization"

   ; EOF leads to no initialization
   (with-input-from-string "" make-node)

   (with-input-from-string INIT_MSG
     (lambda ()
       (define output
         (with-output-to-string
           (lambda ()
             (define node (make-node))
             (check-equal? (send node id) "n3"))))
       (define msg (string->jsexpr output))
       (check-match msg
                    (hash-table
                     ('src "n3")
                     ('dest "c1")
                     ('body (hash-table
                             ('in_reply_to 1)
                             ('type "init_ok"))))))))

  (test-case
   ; no thread support yet
   "Basic handling"

   (define echo-msg "")
   (with-input-from-string (string-append INIT_MSG echo-msg)
     (lambda ()
       (define output
         (with-output-to-string
           (lambda ()
             (define node (make-node))
             (add-handler node 'echo (lambda (req) (fail "TODO")))
             (send node run))))
       (define msg (string->jsexpr output))
       (check-match msg
                    (hash-table
                     ('src "n3")
                     ('dest "c1")
                     ('body (hash-table
                             ('in_reply_to 1)
                             ('type "init_ok")))))))))
