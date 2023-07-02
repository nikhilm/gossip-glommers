#!/bin/bash
# raco make 01_echo_new.rkt
# raco exe 01_echo_new.rkt
export PLTSTDERR="error debug@maelstrom"
echo '{
  "src": "c1",
  "dest": "n1",
  "body": {
    "type":     "init",
    "msg_id":   1,
    "node_id":  "n3",
    "node_ids": ["n1", "n2", "n3"]
  }
}
{
  "src": "c1",
  "dest": "n1",
  "body": {
    "type": "echo",
    "msg_id": 1,
    "echo": "Please echo 35"
  }
}
' | racket ./01_echo_new.rkt
