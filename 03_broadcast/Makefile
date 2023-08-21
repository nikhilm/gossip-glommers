all: 3a 3b 3c

3a: 3a.rkt ../maelstrom/*.rkt
	raco make 3a.rkt
	raco exe 3a.rkt

3b: 3b.rkt ../maelstrom/*.rkt
	raco make 3b.rkt
	raco exe 3b.rkt

3c: 3c.rkt ../maelstrom/*.rkt
	raco make 3c.rkt
	raco exe 3c.rkt

3d: 3d.rkt ../maelstrom/*.rkt
	raco make 3d.rkt
	raco exe 3d.rkt

3c-test: 3c
	PLTSTDERR="debug@broadcast" $(HOME)/maelstrom/maelstrom test -w broadcast --bin $(PWD)/3c --node-count 5 --time-limit 20 --rate 10 --nemesis partition

3d-test: 3d
	PLTSTDERR="debug@broadcast" $(HOME)/maelstrom/maelstrom test -w broadcast --bin $(PWD)/3d --node-count 25 --time-limit 20 --rate 100 --latency 100
