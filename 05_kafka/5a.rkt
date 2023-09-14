#lang racket

(require maelstrom
         maelstrom/message)

(define-logger kafka)
(define node (make-node))

; data is actually a pair (offset index . element)
; this way we can use a list 
(struct partition (next-offset data))

(struct Send (ch key msg))
(struct Poll (ch offsets))
(struct Commit-Offsets (ch offsets))
(struct List-Committed (ch keys))
(define manager
  (thread
   (lambda ()
     (let loop ()
       (match (thread-receive)
         [(Send ch key msg) (raise "TODO")]
         [(Poll ch offsets) (raise "TODO")]
         [(Commit-Offsets ch offsets) (raise "TODO")]
         [(List-Committed ch keys) (raise "TODO")])
       (loop)))))

; My first macro!
(define-syntax (op stx)
  (syntax-case stx ()
    [(_ manager op args ...)
     #'(let ([ch (make-channel)])
         (thread-send manager (op ch args ...))
         (channel-get ch))]))

(add-handler node
             "send"
             (lambda (req)
               (respond req (op manager Send (message-ref req 'key) (message-ref req 'msg)))))

(add-handler node
             "poll"
             (lambda (req)  
               (respond req (op manager Poll (message-ref req 'offsets)))))

(add-handler node
             "commit_offsets"
             (lambda (req)
               (op manager Commit-Offsets (message-ref req 'offsets))
               (respond req)))

(add-handler node
             "list_committed_offsets"
             (lambda (req)
               (respond req (op manager List-Committed (message-ref req 'keys)))))

(module+ main
  (run node))