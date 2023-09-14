#lang racket

(require maelstrom
         maelstrom/message)

(define-logger kafka)
(define node (make-node))

(add-handler node
             "send"
             (lambda (req)
               (respond req (hash 'offset 0))))

(add-handler node
             "poll"
             (lambda (req)
               (respond req (hash 'msgs (hash)))))

(add-handler node
             "commit_offsets"
             (lambda (req)
               (respond req)))

(add-handler node
             "list_committed_offsets"
             (lambda (req)
               (respond req (hash 'offsets (hash)))))

(module+ main
  (run node))