01_echo: 01_echo.rkt
	raco make 01_echo.rkt && raco exe 01_echo.rkt

test: 01_echo
	$(HOME)/maelstrom/maelstrom test -w echo --bin $(PWD)/01_echo --node-count 1 --time-limit 10
