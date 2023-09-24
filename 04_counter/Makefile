all: 4

4: 4.rkt ../maelstrom/*.rkt
	raco make 4.rkt
	raco exe 4.rkt

4-test: 4
	PLTSTDERR="error debug@counter" $(HOME)/maelstrom/maelstrom test -w g-counter --bin $(PWD)/4 --node-count 3 --rate 100 --time-limit 20 --nemesis partition
