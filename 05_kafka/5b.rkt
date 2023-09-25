#lang racket

;; With more than 1 node, here are the operational semantics we need.
;; SC: Sequential Consistency
;; Lin: Linearizability
;;
;; send - this is a write, and regardless of which node it happens on, the linear order of the partition
;; should remain consistent across all nodes. Do we need SC or Lin? First, the offset returned for new sends
;; should be consistent across nodes. That is, if n1 receives A and n2 receives B concurrently, they should
;; return different (and increasing) offsets. Either of these is valid.
;; A at offset 1000, B at offset 1001
;; A at offset 1001, B at offset 1000
;; However these are not valid
;; A at offset 1000, B at offset 1000
;; Seems to me like this only requires SC. Even if in wall time (the real time requirement for Lin), A
;; is sent before B, it is OK for A to receive an offset larger than B.
;; This needs a CAS with the old data and new data. This is a bit concerning in terms of our RPC messages
;; getting larger and larger (right?)
;;
;; poll - this is a read-only operation. As long as we are storing partitions in only one place (one of the kv
;; stores), we will always return a consistent view. However there may be stale reads. This is OK. SC seems
;; enough for this.
;;
;; commit-offsets - since this takes an offset as input, and "commits" it, and read-committed expects to then
;; see that offset, even if the read is issued to another node (no stale read allowed), this will require Lin.
;;
;; read-committed - read from a Lin, so always correct.
;;
;; The key seems to be to store the actual partition data in seq-kv and the current offset record in lin-kv.
;;
;; Assumption: Clients are not malicious/buggy and won't issue a commit-offset for an offset that does not exist.
;; Although even if they violated that assumption, nothing bad would really happen.
;;
;; Given we are going to rely on the KV stores, each handler in the process could do its own thing.
;; I don't think we require the single manager thread here unlike 5a.

(require maelstrom
         maelstrom/kv
         maelstrom/message)

(define-logger kafka)

(define (at-most lst n)
  (with-handlers ([exn:fail:contract? (thunk* lst)])
    (take lst n)))

(define (after-offset part-data offset)
  (dropf
   part-data
   (lambda (offset-element)
     (< (first offset-element) offset))))

(define node (make-node))

(add-handler node
             "send"
             (λ (req)
               ; returns (values <next-offset> <number of iterations to finish the CAS>)
               (define (send key new-val)
                 (let loop ([iter 1])
                   (define current (kv-read seq-kv key null))
                   ; We use the length as the offset to save storage, but this does require iteration and
                   ; so might be slower. TODO: Evaluate
                   (define next-offset (length current))
                   (define new (append current (list new-val)))
                   (if (kv-cas seq-kv key current new #:create-if-missing? #t)
                       (values next-offset iter)
                       (loop (add1 iter)))))
               
               (define key (message-ref req 'key))
               (define new-val (message-ref req 'msg))
               (define-values (offset attempts) (send key new-val))
               (log-kafka-debug "send CAS for ~v: ~v took ~v attempts, got offset ~v." key new-val attempts offset)
               (respond req (hash 'offset offset))))


(add-handler node
             "poll"
             (λ (req)
               (define key-offsets (message-ref req 'offsets))
               (define response
                 (for/hash ([(key offset) (in-hash key-offsets)])
                   ; this is also inefficient
                   (define full-partition (kv-read seq-kv (symbol->string key) null))
                   ; bit concerned if the drop has an off by one error.
                   ; manufacture offsets
                   (define partition-data (at-most (drop full-partition offset) 5))
                   (values key (for/list ([item (in-list partition-data)]
                                          [cur-offset (in-naturals offset)])
                                 (list cur-offset item)))))
               (respond req (hash 'msgs response))))


(add-handler node
             "commit_offsets"
             (λ (req)
               (define (commit key offset)
                 (let loop ()
                   (define current (kv-read lin-kv key -1))
                   (if (< current offset)
                       ; only update if this would advance the offset.
                       (begin
                         (unless (kv-cas lin-kv key current offset #:create-if-missing? #t)
                           (loop)))
                       void)))
               
               (define key-offsets (message-ref req 'offsets))
               (for ([(key offset) (in-hash key-offsets)])
                 (commit (symbol->string key) offset))
               (respond req)))

(add-handler node
             "list_committed_offsets"
             (λ (req)
               (define keys (message-ref req 'keys))
               (define offsets (for*/hash ([key (in-list keys)]
                                           #:do [(define read-result (kv-read lin-kv key #f))]
                                           #:when read-result)
                                 (values (string->symbol key) read-result)))
               (respond req (hash 'offsets offsets))))

(module+ main
  (run node))