#lang racket/base

(provide make-node
         add-handler
         run
         rpc
         send
         respond
         node?
         node-id
         known-peers)

(require json
         maelstrom/message
         racket/contract
         racket/function
         racket/hash
         racket/list
         racket/match
         racket/port
         racket/string)

(define-logger maelstrom)

; Used to preserve context to offer an intuitive API
; for handlers where they can just call send or respond.
(define current-node (make-parameter #f))
(define current-node-main-thread (make-parameter #f))

(struct node
  ([id #:mutable]
   handlers
   [peers #:mutable]
   [msg-id #:mutable]
   ; hash table from `in_reply_to` integer to a callback
   rpc-handlers))

(struct Output (message))
(struct Input (message))
(struct Rpc (message response-handler))

(define/contract (make-node)
  (-> node?)
  (node #f (make-hash) null 0 (make-hasheqv)))

(define/contract (respond request [additional-body (hash)])
  (->* (message?) (hash?) void)
  (define response
    (hash 'body
          (hash-union additional-body
                      ; this is second so the user doesn't accidentally edit the crucial keys.
                      (hash 'type (string-append (message-type request) "_ok")
                            'in_reply_to (message-id request)))))

  (send (message-sender request) response))

(define/contract (send dest msg)
  (-> string? hash? void)
  (when (not (current-node-main-thread))
    (error "Cannot call send outside the execution context of a handler"))
  (define with-deets (add-dest (add-src msg) dest))
  (thread-send (current-node-main-thread) (Output with-deets)))

(define/contract (rpc dest msg response-handler)
  (-> string? any/c (-> message? any/c) void)
  (when (not (current-node-main-thread))
    (error "Cannot call send outside the execution context of a handler"))
  (define with-deets (add-dest (add-src msg) dest))
  (thread-send (current-node-main-thread) (Rpc with-deets response-handler)))
  
(define/contract (add-handler node type handler)
  (node? string? (message? . -> . any/c) . -> . void)
  (hash-set! (node-handlers node) type handler))

(define known-peers
  (case-lambda
    [() (node-peers (current-node))]
    [(n)
     (unless (node? n)
       (raise-argument-error 'known-peers "node?" n))
     (node-peers n)]))

(define/contract (run node)
  (-> node? void)
  (define main-cust (make-custodian))
  (parameterize ([current-custodian main-cust])
    (initialize node)

    (define reader-thread (spawn-reader-thread (current-thread)))

    ; Since a handler returns the jsexpr to write, if it returns a malformed
    ; jsexpr, then the stack trace isn't very useful, as only the main loop is
    ; present. Log the value for some slightly useful messaging.
    (define (write-exn-handler msg e)
      (log-maelstrom-error "Error writing '~v'" msg)
      (raise e))
    
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
                     (if dispatched-thread
                         (loop (cons dispatched-thread dispatched)
                               done-with-inputs)
                         (loop dispatched done-with-inputs))]
                    
                    [(Output msg)
                     (with-handlers
                         ([exn:fail?
                           (curry write-exn-handler msg)])
                       (write-msg node msg))
                     (loop dispatched done-with-inputs)]

                    [(Rpc msg response-handler)
                     (define next-id (next-outgoing-id node))
                     (hash-set! (node-rpc-handlers node) next-id response-handler)
                     (with-handlers
                         ([exn:fail?
                           (curry write-exn-handler msg)])
                       (write-msg-int next-id msg))
                     (loop dispatched done-with-inputs)])))
               
               
               (for/list ([d (in-list dispatched)])
                 (handle-evt d
                             (λ (_)
                               ; thread died
                               (loop (remq d dispatched) done-with-inputs)))))))

    ; go through any final pending tasks in the queue
    (let loop ()
      (match (thread-try-receive)
        [(Output msg)
         (with-handlers
             ([exn:fail?
               (curry write-exn-handler msg)])
           (write-msg node msg))
         (loop)]
        [#f void])))

  ; shut down all handlers before exiting
  (custodian-shutdown-all main-cust))

(define (write-msg-int id msg)
  (define js (hash-set msg 'body
                       (hash-set (message-body msg) 'msg_id id)))
  (write-json js)
  (newline)
  (flush-output)
  (log-maelstrom-debug "~v: Wrote ~v" (current-inexact-monotonic-milliseconds) js))

(define (next-outgoing-id node)
  (define next-id (add1 (node-msg-id node)))
  (set-node-msg-id! node next-id)
  next-id)

(define (write-msg node msg)
  (write-msg-int (next-outgoing-id node) msg))

(define (spawn-reader-thread main-thread)
  (thread
   (lambda ()
     (for ([input-msg (in-port read-json)])
       (log-maelstrom-debug "~v: Got new input ~v" (current-inexact-monotonic-milliseconds) input-msg)
       (thread-send main-thread (Input input-msg)))
     
     (log-maelstrom-debug "~v: Received EOF on input. Stopping reader thread." (current-inexact-monotonic-milliseconds)))))

(define (add-src response)
  (hash-set response 'src (node-id (current-node))))

(define (add-dest response dest)
  (hash-set response 'dest dest))

(define (rpc-response? msg)
  (hash-has-key? (message-body msg) 'in_reply_to))

(define (remove-and-get-rpc-handler node msg-id)
  (define response-handler (hash-ref (node-rpc-handlers node) msg-id #f))
  (hash-remove! (node-rpc-handlers node) msg-id)
  response-handler)

(define (find-handler node msg)
  ; regular handlers are returned directly
  ; RPC handlers are removed from the hash table.
  (if (rpc-response? msg)
      (remove-and-get-rpc-handler node (message-ref msg 'in_reply_to))
      (hash-ref (node-handlers node) (message-type msg))))

(define (dispatch-handler node message handler)
  ; This custodian isn't used for anything right now, but
  ; could be used to time out handlers.
  (define cust (make-custodian))
  (parameterize ([current-custodian cust]
                 [current-node node]
                 [current-node-main-thread (current-thread)])
    (thread
     (lambda ()
       (with-handlers
           ([exn:fail? (lambda (e)
                         (log-maelstrom-error "Error while dispatching handler ~v for message type ~v" handler (message-type message))
                         (raise e))])
         (handler message))))))

(define/contract (dispatch node message)
  (-> node? message? (or/c thread? #f))
  (define maybe-handler (find-handler node message))
  (if maybe-handler
      (dispatch-handler node message maybe-handler)
      #f))

(define/contract (initialize node)
  (-> node? void)
  ; Initialize. the initialize function is just a handler, but
  ; we block on reading the response instead of running it concurrently.
  (add-handler node "init" initialize-handler)
  (let ([msg (read-json)])
    (unless (eof-object? msg)
      (dispatch node msg)))
  ; this is not very robust, since if init is not the first
  ; message sent, then we will dispatch on the wrong handler
  (match-let ([(Output msg) (thread-receive)])
    (write-msg node msg))

  (unless (node-id node)
    (error "node id unset. not initialized?")))

(define/contract (initialize-handler msg)
  (-> message? void)
  (when (node-id (current-node))
    (error "Already initialized"))
  (set-node-id! (current-node) (message-ref msg 'node_id))
  (set-node-peers! (current-node) (remove (message-ref msg 'node_id) (message-ref msg 'node_ids)))
  (respond msg))


(module+ test
  (require rackunit
           racket/function)
  
  
  (define INIT_MSG (with-input-from-file
                       (build-path "test-data" "init-msg.json")
                     port->string))
  (define ECHO_MSG (with-input-from-file
                       (build-path "test-data" "echo-msg.json")
                     port->string))

  (test-case
   "Initialization"

   ; EOF leads to no initialization
   (with-input-from-string
       ""
     (lambda ()
       (define node (make-node))
       (check-false (node-id node))))

   (define output
     (with-input-from-file (build-path "test-data" "init-msg.json")
       (lambda ()
         (with-output-to-string
           (lambda ()
             (define node (make-node))
             (check-equal? (known-peers node) null)
             (run node)
             (check-equal? (node-id node) "n3")
             (check-equal? (known-peers node) (list "n1" "n2")))))))
   (define actual-response (string->jsexpr output))
   (check-equal? actual-response
                 (with-input-from-file (build-path "test-data" "expected-init-response.json")
                   read-json)))

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
     (define node (make-node))
     (add-handler node
                  "echo"
                  (lambda (req)
                    (check-equal? (known-peers) (list "n1" "n2"))
                    (respond req (hash 'echo (message-ref req 'echo)))))
     (run node)))

  (test-case
   "If a handler throws an exception, it is logged, but run still exits"
   (define node (make-node))
   (add-handler node
                "echo"
                (lambda (req)
                  (error "Intentional error")))
   (parameterize ([current-output-port (open-output-nowhere)])
     (with-input-from-string
         (string-append INIT_MSG ECHO_MSG)
       (thunk (run node)))))

  (test-case
   "RPC: Support waiting for a sent message's response"
   (define-values (read-end write-end) (make-pipe))
   (define-values (out-read-end out-write-end) (make-pipe))

   (define waiter (make-semaphore 0))
   (define node (make-node))

         
   (add-handler node
                "echo"
                (lambda (req)
                  (rpc
                   "c1"
                   (make-message (hash 'type "greet" 'name "nikhil"))
                   (lambda (_) (semaphore-post waiter)))))

   (thread
    (lambda ()
      (write-string (string-append INIT_MSG ECHO_MSG) write-end)
      (read-json out-read-end)
      (check-equal? (message-type (read-json out-read-end)) "greet")
      (write-json #hasheq((src . "c1")
                          (dest . "n3")
                          (body . #hasheq((type . "greet_ok")
                                          (message . "Hello Nikhil!")
                                          (in_reply_to . 2)))) write-end)
      ; wait for the rpc handler to be invoked.
      (semaphore-wait waiter)
      (close-output-port write-end)))
   (parameterize ([current-input-port read-end]
                  [current-output-port out-write-end])
     (run node))))