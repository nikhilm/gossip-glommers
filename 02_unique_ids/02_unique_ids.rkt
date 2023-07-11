#lang racket
(require maelstrom)

(define (incr-id box)
  (let loop ()
    (define old (unbox box))
    (define new (add1 old))
    (if (box-cas! box old new)
        new
        (loop))))

(module+ main
  (define node (make-std-node))
  (define id-box (box 0))
  (add-handler
   node
   "generate"
   (lambda (req)
     (respond
      (make-response
       req
       `(id . ,(format "~v_~v" (node-id node) (incr-id id-box)))))))
  (run node))