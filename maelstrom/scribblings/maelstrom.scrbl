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

@section[#:tag "introduction"]{Introduction}

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
                (respond req (hash 'echo (message-ref req 'echo))))) 

 (module+ main
   (run node))
 ]

built into a binary using:

@verbatim{
 raco exe echo.rkt
}

and then run as:

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

@racket[run] will only return once @racket[current-input-port] is closed and all handlers have returned. To forcibly shut it down, you can spawn it in a separate @racket[thread] and use @racket[kill-thread].

It is undefined behavior to call @racket[run] on the same node more than once!
}

@section{Sending messages}

This library uses Racket's parameters and dynamic scoping to make responding to messages more convenient.
The handler code does not need to refer to the @racket[node?]. Instead handlers are invoked with the dynamic context suitably modified such that all these functions no which node to act on.

Any sub-threads spawned by handlers will inherit the correct bindings automatically. See @hyperlink["https://github.com/nikhilm/gossip-glommers/blob/0c1662b3f2c62efbe7f3a6dd6a8355a8f817a453/03_broadcast/3d.rkt"]{this solution to challenge #3d} that spawns a @tt{spawn-minder} thread within the @tt{topology} handler, and the @tt{spawn-minder} thread is still able to use @racket[rpc].

@defproc[(send [dest string?] [msg hash?]) void]{
Send a new message to the peer with id @racket[dest]. @racket[msg] should contain at least a @racket['body]. It is recommended to use @racket[make-message]. No response is expected from the peer. To listen for responses, use @racket[rpc].
}

@defproc[(respond [request message?] [additional-body hash? (hash)]) void]{
A convenience function to use to respond to the message which caused this handler to be run. This will automatically fill in the appropriate @racket['type] and @racket['in_reply_to], and send the message to the original sender of @racket[request].

@racket[request] will usually be the message received by the handler procedure. Any additional body parameters can be supplied in the @racket[additional-body] hash. See the example in @secref["introduction"].
}

@defproc[(rpc [dest string?] [msg hash?] [proc (message? . -> . any/c)]) void]{
Sends @racket[msg] to @racket[dest] similar to @racket[send]. In addition, @racket[proc] will be called when the peer responds to this specific @racket[msg]. This is correlated by @racket['msg_id] and @racket['in_reply_to] according to the Maelstrom protocol. @racket[proc] receives the message sent by the peer.
      
Similar to @racket[add-handler] handlers, @racket[proc] is called in a new @racket[thread].

Note that @racket[proc] is stored until a response is received. This means if peers never respond to messages, memory leaks are possible. There is no solution to this right now, as Maelstrom is not for building production services.
}

@section{Other node operations}

@defproc[
 (node-id [n node?]) (or/c any/c #f)]{Returns the id assigned to this node. Returns @racket[#f] until the node is initialized. This is guaranteed to be set when called within message handlers.}

@defproc[
 (known-peers [n node?]) (listof string?)]{A list of peers of this node as notified by the @tt{"init"} message's @tt{"node_ids"} field. The current node's id is @emph{not present} in this list. To receive the topology sent by most Maelstrom workloads, a custom handler for @tt{"topology"} should be added.}

@section[#:tag "message-api"]{The Message API}

@defmodule[maelstrom/message]

Messages are simply @racket[jsexpr?]s with some additional semantics required by the @hyperlink["https://github.com/jepsen-io/maelstrom/blob/10f5c7f61e0eb113a6b12e8fdf13ac876245b94a/doc/protocol.md#messages"]{Maelstrom protocol}. Because of this, all keys are always Racket symbols.

@defproc[(message? [msg any/c]) bool?]{Returns true if @racket[msg] is a valid Maelstrom protocol message.}

@defproc[(message-ref [msg message?] [key symbol?]) jsexpr?]{Helper to directly access @racket[key] in the @racket[msg]'s @racket['body].}

@defproc[(message-body [msg message?]) jsexpr?]{Get the entire @racket[msg] @racket['body].}

@defproc[(message-sender [msg message?]) jsexpr?]{Get the id of the node that send @racket[msg].}

@defproc[(message-id [msg message?]) jsexpr?]{Get the id of @racket[msg].}

@defproc[(message-type [msg message?]) jsexpr?]{Get the @racket['type] of the @racket[msg].}

@defproc[(make-message [body jsexpr?]) (hash/c symbol? jsexpr?)]{Create a @bold{partially valid} message-like hash based where the @racket[body] is inserted as the @racket['body] in the resulting @racket[hash]. This can be used to create messages that can be sent to @racket[send] or @racket[rpc].}

@racketblock[
 (add-handler
  node
  "my-message"
  (lambda (req)
    (send "n3"
          (make-message
           (hash 'type "another-type"
                 'field1 58
                 'field2 (list "multiple" "items"))))))
 ]

@section{Logging}

The library logs to the @tt{maelstrom} logger. As an example, to see debug messages, you can run the program with the @exec{PLTSTDERR="debug@"@"maelstrom"} environment variable.