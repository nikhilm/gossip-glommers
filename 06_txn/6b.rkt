#lang racket

(require maelstrom
         maelstrom/message)

(define-logger txn)

; Bailis et. al. "Highly Available Transactions: Virtues and Limitations" was the only source I could
; find that explains Read Uncommitted and Read Committed as a short blurb not drowned in symbols and theory.
; The Jepsen website also does, but it doesn't say anything about how to implement something like this.
; https://www.vldb.org/pvldb/vol7/p181-bailis.pdf
;
; For Read Uncommitted, the basic idea is to impose a total ordering on all transactions.
; This ordering can be deterministic by using the node ID + sequence number as the ordering key.
; Each transaction is assigned the number. The node that receives a client request stamps the
; transaction with its next sequence number. It then commits to itself, and also attempts to send
; an RPC to peers.
; Reads can immediately be read from the store. Writes perform last-writer-wins based on the
; transaction's sequence number.

; gets JSON encoded as a list
(struct txn-id (seq node))

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

(define/contract (txn-id-< seq1 seq2)
  (-> txn-id? txn-id? boolean?)
  (let ([n1 (txn-id-node seq1)]
        [n2 (txn-id-node seq2)])
   (cond
    [(= n1 n2) (< (txn-id-seq seq1) (txn-id-seq seq2))]
    [else (< n1 n2)])))

(module+ test
  (require rackunit)
  
  (check-equal? (txn-id->jsexpr (jsexpr->txn-id (list 2348 98))) (list 2348 98))
  (check-exn exn:fail:contract?
             (lambda ()
               (jsexpr->txn-id (hash 'foo 532))))

  (check-true (txn-id-< (txn-id 457 1) (txn-id 982 1)))
  (check-false (txn-id-< (txn-id 457 1) (txn-id 457 1)))
  (check-false (txn-id-< (txn-id 457 1) (txn-id 400 1)))

  (check-true (txn-id-< (txn-id 457 1) (txn-id 2 13))))

; a txn-store is just a hash
; where the values are the value and the largest txn-id that last performed a write.
(define (value pair)
  (first pair))

(define (w-txn pair)
  (second pair))

; in 6b, reads never care about the transaction
(define (store-ref store k)
  (value (hash-ref store k '(null . ,#f))))

; returns the new store.
; to get the written value, callers can perform an immediate store-ref.
; v should be a (value . txn) pair
(define (store-set store k v)
  (hash-update store k
               (lambda (old-v)
                 (if (txn-id-< (w-txn old-v) (w-txn v))
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
                 [new-store store])
                ([operation (in-list txn-req)])
        (match operation
          [(list "r" k 'null)
           (values (cons (list "r" k (store-ref new-store k)) resp)
                   new-store)]

          [(list "w" k v)
           (define updated (store-set new-store k (v . txn-id)))
           ; the spec seems to say the response for writes should be the value
           ; that was sent in. 6b has no notion of failing a transaction.
           (values (cons (list "w" k v) resp)
                   updated)])))
    (channel-put resp-ch resp)
    (loop new-store)))

(module+ main
  (define node (make-node))
  (define the-txn-id )
  (define txn-processor
    (thread txn-processor-loop))
  
  (add-handler node
               "txn"
               (lambda (req)
                 ; TODO: A simpler way is to just have a semaphore
                 ; and call-with-semaphore to incr/init the txn-id from here
                 ; and that way each handler run mints a txn-id and sends it to the
                 ; processor loop.
                 (define ch (make-channel))
                 (thread-send txn-processor (cons ch (message-ref req 'txn)))
                 ; TODO: Perform peer RPC
                 (respond req (hash 'txn (channel-get ch)))))

  ; TODO: Set up peer rpc handlers

  ; TODO: Do we extend maelstrom to allow nodes to define their own "init", so that
  ; we can get the node id and mint the first txn-id?
  ; or do we mint a new txn-id into a box the first time the handler runs
  ; and how do we then propagate that to the txn-processor thread so it can manage it from then on?
  
  (run node))