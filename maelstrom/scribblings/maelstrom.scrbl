#lang scribble/manual
@require[@for-label[maelstrom
                    maelstrom/message
                    racket/base
                    racket/contract
                    json]]

@title{A Racket client for the Maelstrom distributed systems test harness}
@author{Nikhil Marathe}

@defmodule[maelstrom]

@hyperlink["https://github.com/jepsen-io/maelstrom"]{Maelstrom} is a workbench for learning distributed systems by writing your own. This is a library to allow implementing a Maelstrom server node in Racket, similar to @hyperlink["https://github.com/jepsen-io/maelstrom/tree/main/demo"]{existing implementations in other languages}.

Familiarity with Maelstrom terminology is assumed. The following resources are handy:

@itemlist[@item{@hyperlink["https://github.com/jepsen-io/maelstrom/blob/main/doc/01-getting-ready/index.md"]{Maelstrom: Getting Started}}
          @item{@hyperlink["https://github.com/jepsen-io/maelstrom/blob/main/doc/02-echo/index.md"]{Maelstrom: A simple echo server}}
          @item{@hyperlink["https://fly.io/dist-sys/1/"]{Gossip Glomers Challenge #1}}]

@section{Introduction}

The typical implementation of a node will involve:

@itemlist[#:style 'ordered
          @item{Creating a node}
          @item{Adding handler functions}
          @item{In a main submodule, running the node.}]

For example, @hyperlink["https://fly.io/dist-sys/1/"]{Challenge #1 Echo} would be written as:

@racketblock[
 ;; echo.rkt
 (require maelstrom
          maelstrom/message)

 (define node (make-node))
 (add-handler node
              "echo"
              (lambda (req)
                (respond
                 (make-response req
                                `(echo . ,(message-ref req 'echo))))))

 (module+ main
   (run node))
 ]

built into a binary using

@verbatim{
   raco exe echo.rkt
}

and then run as

@verbatim{
maelstrom test -w echo --bin echo --node-count 1 --time-limit 10
}

@section{Creating a node}


@deftogether[(
              @defproc[(node? [n any/c]) boolean?]
               @defproc[(make-node) node?]
               )]{Creates a new node.}

@section{Adding handlers}

@defproc[(add-handler [node node?] [type string?] [proc (message? . -> . any/c)]) void]{
 Add a handler for messages received with the @literal{'type} key in the message body set to this string. Only one handler can exist for a particular type.
 @bold{Any handler added for @literal{"init"} will get replaced by the default initialization handler!}

 The handler receives a message (see the @secref["message-api"]). Its return value is ignored.
 Each handler invocation runs in its own @racket[thread] to not block other handlers. Errors are logged to the maelstrom logger.
}

@section{Running a node}

@defproc[(run [node node?]) void]{
 Begins running a node. This is a @emph{blocking} call. It will use @racket[current-input-port] to read messages sent to the node and @racket[current-output-port] to write outgoing messages. To ensure preconditions are satisfied, @racket[run] expects a @tt{"init"} message as the first message.
}

@section{Sending messages}

This library uses Racket's parameters and dynamic scoping to make responding to messages more convenient.
The handler code does not need to refer to the @racket[node?]. Instead handlers are invoked with the dynamic context suitably modified such that all these functions no which node to act on.

Any sub-threads spawned by handlers will inherit the correct bindings automatically. See @hyperlink["https://github.com/nikhilm/gossip-glommers/blob/436c63464a413a7d267ed0ede4b6b84840650ac7/03_broadcast/3d.rkt"]{this solution to challenge #3d} that spawns a @tt{spawn-minder} thread within the @tt{topology} handler, and the @tt{spawn-minder} thread is still able to use @racket[rpc].

@defproc[(send [dest string?] [msg hash?]) void]{TODO}

@defproc[(respond [request message?] [additional-body hash? (hash)]) void]{TODO}

@defproc[(rpc [dest string?] [msg hash?] [proc (message? . -> . any/c)]) void]{TODO handler will be called in another thread}

@section{Other node operations}

@defproc[
 (node-id [n node?]) (or/c any/c #f)]{Returns the id assigned to this node. Returns @racket[#f] until the node is initialized. This is guaranteed to be set when called within message handlers.}

@defproc[
 (known-peers [n node?]) (listof string?)]{A list of peers of this node as notified by the @tt{"init"} message's @tt{"node_ids"} field. The current node's id is @emph{not present} in this list. To receive the topology sent by most Maelstrom workloads, a custom handler for @tt{"topology"} should be added.}

@section[#:tag "message-api"]{The Message API}

@defmodule[maelstrom/message]

Short note on how messages are hashes that are jsexprs, and keys are symbols

@defproc[(message? [msg any/c]) bool?]{TODO}

@defproc[(message-ref [msg message?] [key symbol?]) jsexpr?]{Throws if not found}

@defproc[(message-body [msg message?]) jsexpr?]{TODO}

@defproc[(message-sender [msg message?]) jsexpr?]{TODO}

@defproc[(message-id [msg message?]) jsexpr?]{TODO}

@defproc[(message-type [msg message?]) jsexpr?]{TODO}

@defproc[(make-message [body jsexpr?]) (hash/c symbol? jsexpr?)]{TODO}

@section{Logging}

The library logs to the @literal{maelstrom} logger. As an example, to see debug messages, you can run the program with the @exec{PLTSTDERR="debug@"@"maelstrom"} environment variable.