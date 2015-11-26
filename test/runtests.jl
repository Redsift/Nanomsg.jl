using Nanomsg
using Base.Test

# jl_nn_errno_check("Transform")

# println("Symbol tree:", CSymbols.J_NN_ALL)

@assert(isbits(_NNSymbolProperties))

#println("Symbol tree:", CSymbols.J_NN_ALL)

addr = "tcp://127.0.0.1:7789"

pub = Socket(CSymbols.AF_SP, CSymbols.NN_BUS)
sub = Socket(CSymbols.AF_SP, CSymbols.NN_BUS)

bind(pub, addr)
connect(sub, addr)

function loop(msg, sender, recvr)
	send(sender, msg)
	if isa(msg, AbstractString)
		result = recv(recvr, AbstractString, CSymbols.NN_NO_FLAG)
		@assert(msg == result)
	else
		result = recv(recvr, CSymbols.NN_NO_FLAG)
		@assert(msg == result)
	end
end

data = ones(UInt8, 11)

bench_string() = loop("TestMessage", pub, sub)
bench_string_alt() = loop("\u2200 x \u2203 y", pub, sub)
bench_array() = loop(data, pub, sub)

bench_string()


#using Benchmark

#println(compare([bench_string, bench_string_alt, bench_array], 100))

#@time bench_string()
#@time bench_string_alt()
#@time bench_array()