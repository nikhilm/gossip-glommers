all: 5a

5a: 5a.rkt ../maelstrom/*.rkt
	raco make 5a.rkt
	raco exe 5a.rkt

5a-test: 5a
	PLTSTDERR="debug@kafka" $(HOME)/maelstrom/maelstrom test -w kafka --bin $(PWD)/5a --node-count 1 --concurrency 2n --time-limit 20 --rate 1000
