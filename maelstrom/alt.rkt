#lang racket/base

(require json)
(require racket/port)
(require racket/contract)
(require racket/class)
(require racket/logging)
(require racket/list)
(require racket/match)

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

(struct node ([id #:mutable] handlers in out [msg-id #:mutable]))

(define/contract (add-handler node type handler)
  (node? string? (message? . -> . any/c) . -> . void)
  (hash-set! (node-handlers node) type handler))

(define (write-msg-int id msg)
  (define js (hash-set msg 'body
                       (hash-set (message-body msg) 'msg_id id)))
  (log-maelstrom-debug "Writing ~v" js)
  (write-json
   js)
  (newline)
  (flush-output))

(define (write-msg node msg)
  (define next-id (add1 (node-msg-id node)))
  (set-node-msg-id! node next-id)
  (write-msg-int next-id msg))

(struct Output (message))
(struct Input (message))
(struct Input-Closed ())

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
    (match (thread-receive)
      [(Output msg) (write-msg node msg)])

    (unless (node-id node)
      (error "node id unset. not initialized?"))

    #|
    because read-json is blocking, this bit needs to be modified quite significantly.
    First, spawn another thread to read input. it should send a message to the main thread
    mailbox with a complete input message.
    Second, now the main thread needs to distinguish between input messages and write requests.
    Third, the main thread still needs to know when the input is closed
    |#

    (let ([main-thread (current-thread)])
      (thread
       (lambda ()
         (let loop ()
           (define m (read-json))
           (if (eof-object? m)
               (thread-send main-thread (Input-Closed))
               (begin
                 (log-maelstrom-debug "Got new input ~v" m)
                 (thread-send main-thread (Input m))
                 (loop)))))))

    (let loop ([dispatched null]
               [done-with-inputs #f])
      (define dispatch-evts
        (for/list ([d (in-list dispatched)])
          (handle-evt
           d
           (lambda (_)
             ; thread died
             (loop (remq d dispatched) done-with-inputs)))))

      ; if there is at least one handler in progress
      ; or input is not closed, wait for new mailbox messages
      (unless (and (empty? dispatched) done-with-inputs)
        (apply
         sync
         (handle-evt
          (thread-receive-evt)
          (lambda (_)
            (match (thread-receive)
              [(Input msg) (loop (cons (dispatch node msg) dispatched) done-with-inputs)]
              [(Input-Closed) (loop dispatched #t)]
              [(Output msg) (write-msg node msg) (loop dispatched done-with-inputs)])))
         dispatch-evts)))

    ; go through any final pending tasks in the queue
    (let loop ()
      (match (thread-try-receive)
        [(Output msg) (write-msg node msg) (loop)]
        [#f void])))


  ; shut down all handlers before exiting
  (custodian-shutdown-all main-cust))


(define (make-std-node)
  (define n (node #f (make-hash) (current-input-port) (current-output-port) 0))
  ; TODO: If we don't need to add handlers, simplify this.
  n)

; should use the parameterized current message for this thread to derive response values
(define (respond response)
  ; TODO: Add attrs from the current input msg
  (send 'todo-dest response))

(define (add-sender response)
  (hash-set response 'src (node-id (current-node))))

(define (send dest response)
  (thread-send (current-node-main-thread) (Output (add-sender response)))
  (log-maelstrom-debug "Queued up response to ~v" (current-node-main-thread)))

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
  (log-maelstrom-debug "Dispatching on (expecting responses) ~v" (current-thread))
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
  (with-logging-to-port
      (current-error-port)
    (lambda () 
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

      ; this is awkward, but multi-line strings do not allow internal newlines.
      (define ECHO_MSG "{\"src\": \"c1\",\"dest\": \"n1\",\"body\": {\"type\": \"echo\",\"msg_id\": 2,\"echo\": \"Please echo 35\"}}\n\n\n")
  
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
                                 ('type "init_ok"))))))))

      (test-case
       "Echo does not hang"
       (define-values (read-end write-end) (make-pipe))
       (thread
        (lambda ()
          (write-string INIT_MSG write-end)
          (write-string ECHO_MSG write-end)
          (sleep 2)
          
          (write-string ECHO_MSG write-end)
          (close-output-port write-end)))
       (parameterize ([current-input-port read-end])
         (define node (make-std-node))
         (add-handler node
                      "echo"
                      (lambda (req)
                        (respond (make-response req `(echo . ,(message-ref req 'echo))))))
         (run node))))
    #:logger maelstrom-logger 'info)) ; change to 'debug when investigating