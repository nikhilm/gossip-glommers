#lang racket
; TODO: Consider converting to typed racket

(require maelstrom
         maelstrom/message
         (for-syntax racket/syntax))

(define-logger kafka)

; data is actually a list of (list offset index)
; turns out appending at the end of a list is not particularly slow compared to a gvector for this
; specific task.
(struct partition (next-offset committed data) #:transparent)

(define (at-most lst n)
  (with-handlers ([exn:fail:contract? (thunk* lst)])
    (take lst n)))

(define (after-offset part-data offset)
  (dropf
   part-data
   (lambda (offset-element)
     (< (first offset-element) offset))))

(define (append-log logs key msg)
  (define resp-offset #f)
  
  (define (updater part)
    (define offset (partition-next-offset part))
    (set! resp-offset offset)
    (partition (add1 offset)
               (partition-committed part)
               (append (partition-data part) (list (list offset msg)))))
  
  (define (if-not-exists) (partition 0 0 null))
  
  (define new-logs (hash-update logs key updater if-not-exists))
  (values resp-offset new-logs))

(define (poll logs offsets)
  (for/hash ([(key offset) (in-hash offsets)]
             #:do [(define key-sym (symbol->string key))]
             #:when (hash-has-key? logs key-sym))
    (values key (at-most
                 (after-offset
                  (partition-data (hash-ref logs key-sym))
                  offset)
                 5))))

(define (commit-offsets logs offsets)
  (for/fold ([logs logs])
            ([(key offset) (in-hash offsets)])
    (values (hash-update logs (symbol->string key)
                         (lambda (part)
                           (partition (partition-next-offset part)
                                      offset
                                      (partition-data part)))))))

(define (list-committed logs keys)
  (for/hash ([key (in-list keys)]
             #:when (hash-has-key? logs key))
    (values (string->symbol key)
            (partition-committed (hash-ref logs key)))))


(struct req-resp-base (ch))
(struct msg_send req-resp-base (key msg))
(struct msg_poll req-resp-base (offsets))
(struct msg_commit_offsets req-resp-base (offsets))
(struct msg_list_committed_offsets req-resp-base (keys))

(define manager
  (thread
   (lambda ()
     (let loop ([logs (hash)])
       (match (thread-receive)
         [(msg_send ch key msg) (define-values (offset new-logs) (append-log logs key msg))
                                (channel-put ch (hash 'offset offset))
                                (loop new-logs)]
         
         [(msg_poll ch offsets) (channel-put ch (hash 'msgs (poll logs offsets)))
                                (loop logs)]
         
         [(msg_commit_offsets ch offsets) (define new-logs (commit-offsets logs offsets))
                                          (channel-put ch (hash))
                                          (loop new-logs)]
         
         [(msg_list_committed_offsets ch keys) (channel-put ch (hash 'offsets (list-committed logs keys)))
                                               (loop logs)])))))

; My first macro!
(define-syntax (handler stx)
  (syntax-case stx ()
    [(_ node message manager args ...)
     (with-syntax ([msg_struct (format-id #'message "msg_~a" #'message)])
       #'(add-handler node
                      message
                      (lambda (req)
                        (define message-elements (map (curry message-ref req) (list args ...)))
                        (define ch (make-channel))
                        (log-kafka-debug "~v: request  ~v: ~v" (current-inexact-monotonic-milliseconds) message message-elements)
                        (thread-send manager (apply msg_struct ch message-elements))
                        (define r (channel-get ch))
                        (log-kafka-debug "~v: response ~v: ~v" (current-inexact-monotonic-milliseconds) message r)
                        (respond req r))))]))

(define node (make-node))
(handler node "send" manager 'key 'msg)
(handler node "poll" manager 'offsets)
(handler node "commit_offsets" manager 'offsets)
(handler node "list_committed_offsets" manager 'keys)

(module+ main
  (run node))