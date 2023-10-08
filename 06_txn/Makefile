all: 6a 6b 6c

6a: 6a.rkt ../maelstrom/*.rkt
	raco make 6a.rkt
	raco exe 6a.rkt

6b: 6b.rkt ../maelstrom/*.rkt
	raco make 6b.rkt
	raco exe 6b.rkt

6c: 6c.rkt ../maelstrom/*.rkt
	raco make 6c.rkt
	raco exe 6c.rkt

6a-test: 6a
	PLTSTDERR="error debug@txn" $(HOME)/maelstrom/maelstrom test -w txn-rw-register --bin $(PWD)/6a --node-count 1 --time-limit 20 --rate 1000 --concurrency 2n --consistency-models read-uncommitted --availability total

6b-test: 6b
	PLTSTDERR="error debug@txn" $(HOME)/maelstrom/maelstrom test -w txn-rw-register --bin $(PWD)/6b --node-count 2 --concurrency 2n --time-limit 20 --rate 1000 --consistency-models read-uncommitted

6b-test-partition: 6b
	PLTSTDERR="error debug@txn" $(HOME)/maelstrom/maelstrom test -w txn-rw-register --bin $(PWD)/6b --node-count 2 --concurrency 2n --time-limit 20 --rate 1000 --consistency-models read-uncommitted --availability total --nemesis partition

6c-test: 6c
	PLTSTDERR="error debug@txn" $(HOME)/maelstrom/maelstrom test -w txn-rw-register --bin $(PWD)/6c --node-count 2 --concurrency 2n --time-limit 20 --rate 1000 --consistency-models read-committed --availability total –-nemesis partition

6c-test-single: 6c
	PLTSTDERR="error debug@txn" $(HOME)/maelstrom/maelstrom test -w txn-rw-register --bin $(PWD)/6c --node-count 1 --concurrency 2n --time-limit 10 --rate 1000 --consistency-models read-committed --availability total –-nemesis partition

