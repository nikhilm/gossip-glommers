#lang racket/base

(require json)
(require racket/port)
(require racket/contract)
(require racket/class)
(require racket/logging)
(require racket/list)

(module+ test
  (require rackunit))

(provide make-std-node
         add-handler
         run
         send
         respond
         message-ref
         make-response)

(define-logger maelstrom)
(define current-node (make-parameter #f))
(define current-input-msg (make-parameter #f))
(define current-node-main-thread (make-parameter #f))

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

(struct node ([id #:mutable] handlers in out))

(define/contract (add-handler node type handler)
  (node? string? (message? . -> . any/c) . -> . void)
  (hash-set! (node-handlers node) type handler))

(define (write-msg id msg)
  (write-json
   (hash-set msg 'body
             (hash-set (message-body msg) 'msg_id id)))
  (newline)
  (flush-output))

(define/contract (run node)
  (-> node? void)
  (define main-cust (make-custodian))
  (parameterize ([current-custodian main-cust]
                 [current-input-port (node-in node)]
                 [current-output-port (node-out node)])
    ; Initialize. the initialize function is just a handler, but
    ; we block on reading the response instead of running it concurrently.
    (add-handler node "init" initialize)
    (let ([msg (read-json)])
      (unless (eof-object? msg)
        (dispatch node msg)))
    ; this is not very robust, since if init is not the first
    ; message sent, then we will dispatch on the wrong handler
    (write-msg 1 (thread-receive))

    (unless (node-id node)
      (error "node id unset. not initialized?"))

    (let loop ([outgoing-message-id 2]
               [input-closed #f]
               [dispatched null])

      (log-maelstrom-debug "loop ----")


      (define evts
        (for/list ([th (in-list dispatched)])
          (handle-evt th
                      (lambda (th)
                        ; when run, it means that thread exited.
                        (log-maelstrom-debug "thread died ~v" th)
                        (loop outgoing-message-id input-closed (remq th dispatched))))))

      ; ah, but if a thread dies and sync selects that, we may never add a thread-receive
      ; so we won't get any messages to write.
      (log-maelstrom-debug "input-closed? ~v pending dispatches? ~v" input-closed dispatched)
      (define evts1
        (if (and input-closed (empty? dispatched))
            evts
            (begin
              (log-maelstrom-debug "Added thread-receive-evt")
              (cons
               (handle-evt (thread-receive-evt)
                           (lambda (_)
                             (log-maelstrom-debug "new msg to write")
                             (write-msg outgoing-message-id (thread-receive))
                             (loop (add1 outgoing-message-id) input-closed dispatched)))
               evts))))

      (define evts2
        (if input-closed
            evts1
            (begin
              (log-maelstrom-debug "Added input reading")
              (cons
               (handle-evt (read-bytes-evt 1 (current-input-port))
                           (lambda (_)
                             (define msg (read-json))
                             (log-maelstrom-debug "read from input ~v" msg)
                             (if (eof-object? msg)
                                 ; no longer wait on input
                                 (loop outgoing-message-id #t dispatched)
                               
                                 (loop outgoing-message-id #f (cons (dispatch node msg) dispatched)))))
               evts1))))

      (unless (empty? evts2)
        (apply sync evts2))))

  (let loop ()
    (let ([d (thread-try-receive)])
      (log-maelstrom-debug "Got mail? ~v" d)
      (when d
        ; Ugh! Now we don't know the outgoing message id
        (write-msg 1000000 d)
        (loop))))


  ; shut down all handlers before exiting
  (custodian-shutdown-all main-cust))


(define (make-std-node)
  (define n (node #f (make-hash) (current-input-port) (current-output-port)))
  ; TODO: If we don't need to add handlers, simplify this.
  n)

; should use the parameterized current message for this thread to derive response values
(define (respond response)
  ; TODO: Add attrs from the current input msg
  (send 'todo-dest response))

(define (add-sender response)
  (hash-set response 'src (node-id (current-node))))

(define (send dest response)
  (thread-send (current-node-main-thread) (add-sender response)))

; hmm the outgoing message ID should really only be inserted
; by the main thread (so no concurrency necessary) at the time
; of writing

(define (make-response input . additional-body)
  (define response
    (hash 'dest (message-sender input)))
   
  (hash-set response 'body (make-immutable-hasheq
                            (append `((type . ,(string-append (message-type input) "_ok"))
                                      (in_reply_to . ,(message-id input)))
                                    additional-body))))

(define (dispatch node message)
  (-> node? message? void)
  (define handler (hash-ref (node-handlers node) (message-type message)))
  ; This custodian isn't used for anything right now, but
  ; could be used to time out handlers.
  (define cust (make-custodian))
  (parameterize ([current-custodian cust]
                 [current-node node]
                 [current-node-main-thread (current-thread)]
                 [current-input-msg message])
    (log-maelstrom-debug "Dispatching ~v" message)
    (thread (lambda() (handler message)))))

(define (initialize msg)
  (when (node-id (current-node))
    (error "Already initialized"))
  (set-node-id! (current-node) (message-ref msg 'node_id))
  (respond (make-response msg)))


(module+ test
  (with-logging-to-port (current-error-port) (lambda () 
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
                                                (with-input-from-string
                                                    ""
                                                  (lambda ()
                                                    (define node (make-std-node))
                                                    (check-false (node-id node))))

                                                (with-input-from-string INIT_MSG
                                                  (lambda ()
                                                    (define output
                                                      (with-output-to-string
                                                        (lambda ()
                                                          (define node (make-std-node))
                                                          (run node)
                                                          (check-equal? (node-id node) "n3"))))
                                                    (define msg (string->jsexpr output))
                                                    (check-match msg
                                                                 (hash-table
                                                                  ('src "n3")
                                                                  ('dest "c1")
                                                                  ('body (hash-table
                                                                          ('in_reply_to 1)
                                                                          ('type "init_ok")))))))))
    #:logger maelstrom-logger 'info))