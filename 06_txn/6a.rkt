#lang racket

(require maelstrom
         maelstrom/message)

(define-logger txn)


; one of the design mistakes i've been making in previous problems
; is that i often start the "manager" thread outside of the main module.
; which is weird because ideally there shouldn't be any running code before that.
(define (txn-processor-loop)
  (let loop ([store (hash)])
    (match-define (cons resp-ch txn-req) (thread-receive))
    ; hmm we simultaneously
    ; hmm
    ; each for/list iteration is returning something to respond with
    ; but it is also accumulating updates to the store
    ;
    (define-values (resp new-store)
      (for/fold ([resp null]
                 [new-store store])
                ([operation (in-list txn-req)])
        (match operation
          [(list "r" k 'null)
           (values (cons (list "r" k (hash-ref new-store k 'null)) resp)
                   new-store)]

          [(list "w" k v)
           (values (cons (list "w" k v) resp)
                   (hash-set new-store k v))])))
    (channel-put resp-ch resp)
    (loop new-store)))


(module+ main
  (define node (make-node))
  ; If we linearize, we have an obviously consistent and transactional experience :)
  (define txn-processor
    (thread txn-processor-loop))
  
  (add-handler node
               "txn"
               (lambda (req)
                 (define ch (make-channel))
                 (thread-send txn-processor (cons ch (message-ref req 'txn)))
                 (respond req (hash 'txn (channel-get ch)))))
  
  (run node))