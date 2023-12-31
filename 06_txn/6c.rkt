#lang racket

(require maelstrom
         maelstrom/message)

(define-logger txn)

; Bailis et. al. "Highly Available Transactions: Virtues and Limitations" was the only source I could
; find that explains Read Uncommitted and Read Committed as a short blurb not drowned in symbols and theory.
; The Jepsen website also does, but it doesn't say anything about how to implement something like this.
; https://www.vldb.org/pvldb/vol7/p181-bailis.pdf
;
; our 6b implementation is already stronger than Read-Committed, being Monotonic Atomic View if I understand
; correctly, due to the serializing that occurs in the txn processor loop. It is MAV in the single node case,
; particularly preventing g1b and g1c. However this solution isn't responding with aborting transactions yet.
; In essence, our implementation is "correct", but isn't really exercising true transaction aborts.

(struct txn-id (seq node) #:transparent)

(define/contract (txn-id->jsexpr txn)
  (-> txn-id? (list/c natural? natural?))
  (list (txn-id-seq txn) (txn-id-node txn)))

(define/contract (jsexpr->txn-id expr)
  (-> (list/c natural? natural?) txn-id?)
  (txn-id (first expr) (second expr)))

; Only meaningful on the same node.
(define/contract (next-txn-id seq)
  (-> txn-id? txn-id?)
  (txn-id (add1 (txn-id-seq seq)) (txn-id-node seq)))

(define/contract (txn-id-<= seq1 seq2)
  (-> txn-id? txn-id? boolean?)
  (let ([n1 (txn-id-node seq1)]
        [n2 (txn-id-node seq2)])
   (cond
    [(= n1 n2) (<= (txn-id-seq seq1) (txn-id-seq seq2))]
    [else (<= n1 n2)])))

(module+ test
  (require rackunit)
  
  (check-equal? (txn-id->jsexpr (jsexpr->txn-id (list 2348 98))) (list 2348 98))
  (check-exn exn:fail:contract?
             (lambda ()
               (jsexpr->txn-id (hash 'foo 532))))

  (check-true (txn-id-<= (txn-id 457 1) (txn-id 982 1)))
  (check-true (txn-id-<= (txn-id 457 1) (txn-id 457 1)))
  (check-false (txn-id-<= (txn-id 457 1) (txn-id 400 1)))

  (check-true (txn-id-<= (txn-id 457 1) (txn-id 2 13))))

; a txn-store is just a hash
; where the values are the value and the largest txn-id that last performed a write.
(define (value pair)
  (car pair))

(define (w-txn pair)
  (cdr pair))

; in 6b, reads never care about the transaction
(define (store-ref store k)
  (value (hash-ref store k '(null . ,#f))))

; returns the new store.
; to get the written value, callers can perform an immediate store-ref.
; v should be a (value . txn) pair
(define (store-set store k v)
  (hash-update store k
               (lambda (old-v)
                 (if (txn-id-<= (w-txn old-v) (w-txn v))
                     ; perform the update
                     v
                     ; skip the update
                     old-v))
               ; if a value does not exist, this txn wins
               ; if v is set as the default, then applying the updater
               ; will fail the check, so it will stay as is.
               v))


(define (txn-processor-loop)
  (let loop ([store (hash)])
    (match-define (list resp-ch txn-req txn-id) (thread-receive))
    (define-values (resp new-store)
      (for/fold ([resp null]
                 [new-store store]
                 ; cons is used for efficiency. reverse the final list to match expectations.
                 #:result (values (reverse resp) new-store))
                ([operation (in-list txn-req)])
        (match operation
          [(list "r" k 'null)
           (values (cons (list "r" k (store-ref new-store k)) resp)
                   new-store)]

          [(list "w" k v)
           (define updated (store-set new-store k (cons v txn-id)))
           ; the spec seems to say the response for writes should be the value
           ; that was sent in. 6b has no notion of failing a transaction.
           (values (cons (list "w" k v) resp)
                   updated)])))
    (channel-put resp-ch resp)
    (loop new-store)))

(module+ main
  (define node (make-node))

  (define seq-num 0)
  (define seq-sema (make-semaphore 1))
  (define (bump-seq)
    (call-with-semaphore seq-sema
                         (lambda ()
                           (set! seq-num (add1 seq-num))
                           seq-num)))
  
  (define txn-processor
    (thread txn-processor-loop))
  
  (add-handler node
               "txn"
               (lambda (req)
                 (define nid (string->number (substring (node-id node) 1)))
                 (define this-txn (txn-id (bump-seq) nid))
                 (define ch (make-channel))
                 (thread-send txn-processor (list ch (message-ref req 'txn) this-txn))
                 ; no need to block the client on replication.
                 (respond req (hash 'txn (channel-get ch)))
                 
                 (define unacked (list->mutable-set (known-peers)))
                 (let loop ([i 1])
                         (hash 'txn (message-ref req 'txn)
                   (unless (set-empty? unacked)
                     (for ([peer (in-set unacked)])
                       (rpc peer (make-message
                                  (hash 'txn (message-ref req 'txn)
                                        'txn_id (txn-id->jsexpr this-txn)
                                        'type "remote-txn"))
                            (lambda (response)
                              (set-remove! unacked (message-sender response)))))
                     (sleep 0.5)
                     (loop (add1 i)))))))

  (add-handler node
               "remote-txn"
               (lambda (req)
                 (define ch (make-channel))
                 (thread-send txn-processor
                              (list ch
                                    (message-ref req 'txn)
                                    (jsexpr->txn-id (message-ref req 'txn_id))))
                 (channel-get ch)
                 (respond req (hash))))
  
  (run node))
