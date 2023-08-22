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

@section{Creating a node}

@defproc[
 (make-node) node?]{Test}

@defproc[(node? [n any/c]) boolean?]{Test}

@section{Adding handlers}

@defproc[(add-handler [node node?] [type string?] [proc (message? . -> . any/c)]) void]{TODO}

@section{Running a node}

@defproc[(run [node node?]) void]{Note about stdin/stderr and dispatch contexts here}

@section{Sending messages}

Add a note about the use of rpc/send/respond outside the immediate context of a handler.
Due to how thread contexts work (they are inherited by sub threads), it is ok to call these functions in other Racket threads as long as those threads were started from one of the handlers.

@defproc[(send [dest string?] [msg hash?]) void]{TODO}

@defproc[(make-response [request message?] [body any/c]) hash?]{I don't know how to type the additional argument}

@defproc[(respond [msg hash?]) void]{TODO}

@defproc[(rpc [dest string?] [msg hash?] [proc (message? . -> . any/c)]) void]{TODO handler will be called in another thread}

@section{Other node operations}

@defproc[
 (node-id [n node?]) string?]{Returns the id assigned to this node.}

@defproc[
 (known-peers [n node?]) (listof string?)]{A list of peers of this node as notified by the "initialize" message. To receive the topology sent by most Maelstrom workloads, a custom handler for topology should be added.}

@section{The Message API}

@defmodule[maelstrom/message]

Short note on how messages are hashes that are jsexprs, and keys are symbols

@defproc[(message? [msg any/c]) bool?]{TODO}

@defproc[(message-ref [msg message?] [key symbol?]) jsexpr?]{Throws if not found}

@defproc[(message-body [msg message?]) jsexpr?]{TODO}

@defproc[(message-sender [msg message?]) jsexpr?]{TODO}

@defproc[(message-id [msg message?]) jsexpr?]{TODO}

@defproc[(message-type [msg message?]) jsexpr?]{TODO}

@defproc[(make-message [body jsexpr?]) (hash/c symbol? jsexpr?)]{TODO}

Messages are
