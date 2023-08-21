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

Familiarity with Maelstorm terminology is assumed. The following resources are handy:

@itemlist[@item{@hyperlink["https://github.com/jepsen-io/maelstrom/blob/main/doc/01-getting-ready/index.md"]{Maelstorm: Getting Started}}
          @item{@hyperlink["https://github.com/jepsen-io/maelstrom/blob/main/doc/02-echo/index.md"]{Maelstorm: A simple echo server}}
          @item{@hyperlink["https://fly.io/dist-sys/1/"]{Gossip Glomers Challenge #1}}]

@section{Introduction}

@section{Creating a node}

@defproc[
 (make-node) node?]{Test}

@defproc[(node? [n any/c]) boolean?]{Test}

@section{Adding handlers}

@section{Sending messages}

Add a note about the use of rpc/send/respond outside the immediate context of a handler.
Due to how thread contexts work (they are inherited by sub threads), it is ok to call these functions in other Racket threads as long as those threads were started from one of the handlers.

@section{Other node operations}

@defproc[
 (node-id [n node?]) string?]{Returns the id assigned to this node.}

@defproc[
 (known-peers [n node?]) (listof string?)]{A list of peers of this node as notified by the "initialize" message. To receive the topology sent by most Maelstorm workloads, a custom handler for topology should be added.}

@section{The Message API}

Messages are
