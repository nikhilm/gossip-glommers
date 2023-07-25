#lang racket/base

(require json)
(require racket/port)
(require racket/contract)
(require racket/class)
(require racket/logging)
(require racket/list)
(require racket/match)

(require maelstrom/message)

(module+ test
  (require rackunit))

(provide make-std-node
         add-handler
         run
         send
         respond
         message-ref
         make-response
         node-id
         known-node-ids)

(define-logger maelstrom)

; Used to preserve context to offer an intuitive API
; for handlers where they can just call send or respond.
(define current-node (make-parameter #f))
(define current-input-msg (make-parameter #f))
(define current-node-main-thread (make-parameter #f))


(struct node ([id #:mutable] handlers in out [other-nodes #:mutable] [msg-id #:mutable]))
(struct Output (message))
(struct Input (message))

(define/contract (make-std-node)
  (-> node?)
  (node #f (make-hash) (current-input-port) (current-output-port) null 0))

(define (respond response)
  (when (not (current-input-msg))
    (error "Cannot call send outside the execution context of a handler"))
  (send (message-sender (current-input-msg)) response))

(define (send dest response)
  (when (not (current-node-main-thread))
    (error "Cannot call send outside the execution context of a handler"))
  (thread-send (current-node-main-thread) (Output (add-dest (add-src response) dest)))
  (log-maelstrom-debug "Queued up response to ~v" (current-node-main-thread)))

(define (make-response input . additional-body)
  (hash 'body (make-immutable-hasheq
               (append `((type . ,(string-append (message-type input) "_ok"))
                         (in_reply_to . ,(message-id input)))
                       additional-body))))

(define/contract (add-handler node type handler)
  (node? string? (message? . -> . any/c) . -> . void)
  (hash-set! (node-handlers node) type handler))

(define known-node-ids
  (case-lambda
    [() (node-other-nodes (current-node))]
    [(n)
     (unless (node? n)
       (raise-argument-error 'known-node-ids "node?" n))
     (node-other-nodes n)]))

(define/contract (run node)
  (-> node? void)
  (define main-cust (make-custodian))
  (parameterize ([current-custodian main-cust]
                 [current-input-port (node-in node)]
                 [current-output-port (node-out node)])
    (initialize node)

    (define reader-thread (spawn-reader-thread (current-thread)))
    
    (let loop ([dispatched null]
               [done-with-inputs #f])
      ; if there is at least one handler in progress
      ; or input is not closed, wait for new mailbox messages
      ; as well as for all handlers to be done.
      (unless (and (empty? dispatched) done-with-inputs)
        (apply sync
               (handle-evt reader-thread (λ (_) (loop dispatched #t)))
         
               (handle-evt
                (thread-receive-evt)
                (λ (_)
                  (match (thread-receive)
                    [(Input msg)
                     (define dispatched-thread (dispatch node msg))
                     (loop (cons dispatched-thread dispatched)
                           done-with-inputs)]
                    
                    [(Output msg)
                     (write-msg node msg)
                     (loop dispatched done-with-inputs)])))
               
               
               (for/list ([d (in-list dispatched)])
                 (handle-evt d
                             (λ (_)
                               ; thread died
                               (loop (remq d dispatched) done-with-inputs)))))))

    ; go through any final pending tasks in the queue
    (let loop ()
      (match (thread-try-receive)
        [(Output msg) (write-msg node msg) (loop)]
        [#f void])))

  ; shut down all handlers before exiting
  (custodian-shutdown-all main-cust))

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

(define (spawn-reader-thread main-thread)
  (thread
   (lambda ()
     (let loop ()
       (define m (read-json))
       (if (eof-object? m)
           (begin
             (log-maelstrom-debug "Received EOF on input. Stopping reader thread."))
           (begin
             (log-maelstrom-debug "Got new input ~v" m)
             (thread-send main-thread (Input m))
             (loop)))))))


(define (add-src response)
  (hash-set response 'src (node-id (current-node))))

(define (add-dest response dest)
  (hash-set response 'dest dest))

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
    (thread
     (lambda()
       (with-handlers
           ([exn:fail? (lambda (e)
                         (log-maelstrom-error "Error while dispatching handler ~v for message type ~v" handler (message-type message))
                         (raise e))])
         (handler message))))))

(define (initialize node)
  ; Initialize. the initialize function is just a handler, but
  ; we block on reading the response instead of running it concurrently.
  (add-handler node "init" initialize-handler)
  (let ([msg (read-json)])
    (unless (eof-object? msg)
      (dispatch node msg)))
  ; this is not very robust, since if init is not the first
  ; message sent, then we will dispatch on the wrong handler
  (match (thread-receive)
    [(Output msg) (write-msg node msg)])

  (unless (node-id node)
    (error "node id unset. not initialized?")))

(define (initialize-handler msg)
  (when (node-id (current-node))
    (error "Already initialized"))
  (set-node-id! (current-node) (message-ref msg 'node_id))
  (set-node-other-nodes! (current-node) (remove (message-ref msg 'node_id) (message-ref msg 'node_ids)))
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
      ; internal newlines are required to validate the input reader is running in
      ; a separate thread where it is ok for read-json to block. 
      (define ECHO_MSG "{\"src\": \"c1\",\"dest\": \"n1\",\"body\": {\"type\": \"echo\",\"msg_id\": 2,\"echo\": \"Please echo 35\"}}\n\n\n")
  
      
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
                 (check-equal? (known-node-ids node) null)
                 (run node)
                 (check-equal? (node-id node) "n3")
                 (check-equal? (known-node-ids node) (list "n1" "n2")))))
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
       (define-values (out-read-end out-write-end) (make-pipe))
       (define sem (make-semaphore))
       (thread
        (lambda ()
          (write-string INIT_MSG write-end)
          (write-string ECHO_MSG write-end)
          ; wait until the main thread acknowledges it received a response.
          (semaphore-wait sem)
          
          (write-string ECHO_MSG write-end)
          (close-output-port write-end)))

       (thread
        (lambda ()
          (after (check-match (read-json out-read-end)
                              (hash-table
                               ('src _)
                               ('dest _)
                               ('body (hash-table
                                       ('in_reply_to _)
                                       ('type "init_ok")))))
                 (check-match (read-json out-read-end)
                              (hash-table
                               ('src _)
                               ('dest _)
                               ('body (hash-table
                                       ('in_reply_to _)
                                       ('type "echo_ok")))))
                 (semaphore-post sem))
          (check-match (read-json out-read-end)
                       (hash-table
                        ('src _)
                        ('dest _)
                        ('body (hash-table
                                ('in_reply_to _)
                                ('type "echo_ok")))))))
       
       (parameterize ([current-input-port read-end]
                      [current-output-port out-write-end])
         (define node (make-std-node))
         (add-handler node
                      "echo"
                      (lambda (req)
                        (check-equal? (known-node-ids) (list "n1" "n2"))
                        (respond (make-response req `(echo . ,(message-ref req 'echo))))))
         (run node)))

      (test-case
       "If a handler throws an exception, it is logged, but run still exits"
       (parameterize ([current-output-port (open-output-nowhere)])
         (with-input-from-string
             (string-append INIT_MSG ECHO_MSG)
           (lambda ()
             (define node (make-std-node))
             (add-handler node
                          "echo"
                          (lambda (req)
                            (error "Intentional error")))
             (run node)))))

      (test-case
       "RPC: Support waiting for a sent message's response"
       ))
    #:logger maelstrom-logger 'info)) ; change to 'debug when investigating