all: 6a

6a: 6a.rkt ../maelstrom/*.rkt
	raco make 6a.rkt
	raco exe 6a.rkt

6a-test: 6a
	PLTSTDERR="error debug@txn" $(HOME)/maelstrom/maelstrom test -w txn-rw-register --bin $(PWD)/6a --node-count 1 --time-limit 20 --rate 1000 --concurrency 2n --consistency-models read-uncommitted --availability total
