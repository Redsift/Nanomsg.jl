module Nanomsg

using Sockets

export Socket, CSymbols, jl_nn_errno_check, poll
export _nn_errno, _nn_strerror, _nn_symbol_info, _NNSymbolProperties

const LIB = @static Sys.iswindows() ? "nanomsg.dll" : "libnanomsg"

mutable struct NanomsgError <: Exception
    context::AbstractString
    errno::Cint

    NanomsgError(m) = new(m,0)
    NanomsgError(m,e) = new(m,e)
end

function Base.show(io::IO, err::NanomsgError)
	print(io, (err.errno == 0 ? "Nanomsg.jl error, " : "Nanomsg.lib error, errno=$(err.errno), message=$(nn_strerror(err.errno)), "), err.context)
end

mutable struct Socket
    s::Cint

    function Socket(domain::Integer, protocol::Integer)
        p = _nn_socket(domain, protocol)
        if p == -1
            throw(NanomsgError("Socket creation failed", _nn_errno()))
        end

        # 0.8-beta max recv size
        maxSize = convert(Ptr{Nothing}, -1)
        size = convert(Csize_t, sizeof(maxSize))
        _nn_setsockopt(p, CSymbols.NN_SOL_SOCKET, CSymbols.NN_RCVMAXSIZE, maxSize, size)

        socket = new(p)
        finalizer(close, socket)
        return socket
    end
end

function Base.close(socket::Socket)
    if socket.s != -1
        rc = _nn_close(socket.s)
        if rc == -1
            throw(NanomsgError("Socket close failed", _nn_errno()))
        end
        socket.s = -1
    end
	nothing
end

function Base.bind(socket::Socket, endpoint::AbstractString)
    rc = _nn_bind(socket.s, pointer(endpoint))
    if rc == -1
        throw(NanomsgError("Socket bind failed", _nn_errno()))
    end
    nothing
end

function Sockets.connect(socket::Socket, endpoint::AbstractString)
    rc = _nn_connect(socket.s, pointer(endpoint))
    if rc == -1
        throw(NanomsgError("Socket connect failed", _nn_errno()))
    end
    nothing
end

# TODO: Use a in memory IO in addition to the helper string methods
function Sockets.send(socket::Socket, msg::AbstractString, flags::Integer = CSymbols.NN_DONTWAIT)
	size = convert(Csize_t, length(msg.data))
	_send(socket, pointer(msg), size, flags)
end

function Sockets.send(socket::Socket, msg::Array{UInt8}, flags::Integer = CSymbols.NN_DONTWAIT)
	size = convert(Csize_t, length(msg))
	_send(socket, pointer(msg), size, flags)
end

function _send(socket::Socket, msg::Ptr{UInt8}, size::Csize_t, flags::Integer = CSymbols.NN_DONTWAIT)
    rc = _nn_send(socket.s, convert(Ptr{Nothing}, msg), size, flags)
    if rc == -1
    	err = _nn_errno()
    	if err == CSymbols.EAGAIN
    		return nothing
    	end
        throw(NanomsgError("Socket send failed", err))
    end

    if size != rc
    	throw(NanomsgError("Socket sent bytes $rc != $size failed"))
    end

    # println("sent:", rc)
    return rc
end


function Sockets.recv(socket::Socket, ::Type{AbstractString}, flags::Integer = CSymbols.NN_DONTWAIT)
    buf = Array{Ptr{Cchar}}(undef, 1)
    rc = _nn_recv(socket.s, convert(Ptr{Nothing}, pointer(buf)), CSymbols.NN_MSG, flags)
    if rc == -1
    	err = _nn_errno()
    	if err == CSymbols.EAGAIN
    		return nothing
    	end
        throw(NanomsgError("Socket recv failed", err))
    end
    str = bytestring(buf[1], rc)
    _nn_freemsg(convert(Ptr{Nothing}, buf[1]))

    # println("recv(s):", rc, str)
    return str
end

function Sockets.recv(socket::Socket, flags::Integer = CSymbols.NN_DONTWAIT)
    buf = Array{Ptr{Cuchar}}(undef, 1)
    rc = _nn_recv(socket.s, convert(Ptr{Nothing}, pointer(buf)), CSymbols.NN_MSG, flags)
    if rc == -1
    	err = _nn_errno()
    	if err == CSymbols.EAGAIN
    		return nothing
    	end
        throw(NanomsgError("Socket recv failed", err))
    end

    result::Ptr{Cuchar} = buf[1]
    arr = pointer_to_array(result, rc)
    finalizer((val) -> @async _nn_freemsg(convert(Ptr{Nothing}, result)), arr)

    #println("recv(a):", length(arr))
    return arr
end

function poll(sockets::Array{Socket}, pollIn::Bool = true, pollOut::Bool = true, timeout::Integer = -1)
	ct = length(sockets)
	go = ct > 0
	f = 0
	if pollIn
		f = CSymbols.NN_POLLIN
	end
	if pollOut
		f |= CSymbols.NN_POLLOUT
	end

	watch = map(s -> _NNPollFD(s.s, f, 0), sockets)
	ptr = convert(Ptr{Nothing}, pointer(watch))

	@task while go
		rc = _nn_poll(ptr, convert(Cint, ct), convert(Cint, timeout))
		if rc == -1
			throw(NanomsgError("Socket recv failed", _nn_errno()))
		end

		if rc == 0
			# timeout
			go = false
			continue
		end

		i = 1
		for t in watch
			rIn = ((t.revents & CSymbols.NN_POLLIN) != 0)
			rOut = ((t.revents & CSymbols.NN_POLLOUT) != 0)

			if rIn || rOut
				produce((sockets[i], i, rIn, rOut))
			end
			i = i + 1
		end
	end
end

struct _NNPollFD
    fd::Cint
    events::Cshort
    revents::Cshort
end

# Bit type for direct mapping to C struct
struct _NNSymbolProperties
    value::Cint
    name::Ptr{UInt8}
    ns::Cint
    typ::Cint
    unit::Cint

    _NNSymbolProperties() = new(0, 0, 0, 0, 0)
end

function Base.show(io::IO, prop::_NNSymbolProperties)
	name = bytestring(prop.name)

	print(io, "_NNSymbolProperties: value=", prop.value, " name=", name, ", namespace=", prop.ns, ", type=", prop.typ, ", unit=", prop.unit)
end

# Create an SP socket
_nn_socket(domain::Cint, protocol::Cint) = ccall((:nn_socket, LIB), Cint, (Cint, Cint), domain, protocol)

# Close an SP socket
_nn_close(s::Cint) = ccall((:nn_close, LIB), Cint, (Cint,), s)

# Set a socket option
_nn_setsockopt(s::Cint, level::Cint, option::Cint, optval::Ptr{Nothing}, optvallen::Csize_t) = ccall((:nn_setsockopt, LIB), Cint, (Cint, Cint, Cint, Ptr{Nothing}, Csize_t), s, level, option, optval, optvallen)

# Retrieve a socket option
_nn_getsockopt(s::Cint, level::Cint, option::Cint, optval::Ptr{Nothing}, optvallen::Csize_t) = ccall((:nn_getsockopt, LIB), Cint, (Cint, Cint, Cint, Ptr{Nothing}, Csize_t), s, level, option, optval, optvallen)

# Add a local endpoint to the socket
_nn_bind(s::Cint, addr::Ptr{UInt8}) = ccall((:nn_bind, LIB), Cint, (Cint,Ptr{UInt8}), s, addr)

# Add a remote endpoint to the socket
_nn_connect(s::Cint, addr::Ptr{UInt8}) = ccall((:nn_connect, LIB), Cint, (Cint,Ptr{UInt8}), s, addr)

# Remove an endpoint from the socket
_nn_shutdown(s::Cint, how::Cint) = ccall((:nn_shutdown, LIB), Cint, (Cint,Cint), s, how)

# Send a message
_nn_send(s::Cint, buf::Ptr{Nothing}, len::Csize_t, flags::Cint) = ccall((:nn_send, LIB), Cint, (Cint,Ptr{Nothing},Csize_t,Cint), s, buf, len, flags)

# Receive a message
_nn_recv(s::Cint, buf::Ptr{Nothing}, len::Csize_t, flags::Cint) = ccall((:nn_recv, LIB), Cint, (Cint,Ptr{Nothing},Csize_t,Cint), s, buf, len, flags)

# Fine-grained alternative to nn_send
####### nn_sendmsg(3)

# Fine-grained alternative to nn_recv
####### nn_recvmsg(3)

# Allocation of messages
####### nn_allocmsg(3)
####### nn_reallocmsg(3)

_nn_freemsg(buf::Ptr{Nothing}) = ccall((:nn_freemsg, LIB), Cint, (Ptr{Nothing},), buf)


# Manipulation of message control data
####### nn_cmsg(3)

# Multiplexing
_nn_poll(fds::Ptr{Nothing}, nfds::Cint, timeout::Cint) = ccall((:nn_poll, LIB), Cint, (Ptr{Nothing},Cint,Cint), fds, nfds, timeout)

# Retrieve the current errno
_nn_errno() = ccall((:nn_errno, LIB), Cint, ())

# Convert an error number into human-readable string
_nn_strerror(errno::Cint) = ccall((:nn_strerror, LIB), Ptr{UInt8}, (Cint,), errno)
function nn_strerror(errno::Cint)
	if errno == 0
		return nothing
	else
		cstr = _nn_strerror(errno)
		if cstr != C_NULL
			return bytestring(cstr)
		else
			return "Unknown errno"
		end

	end
end

# Check errno and throw an exception if set
function jl_nn_errno_check(context::AbstractString)
	errno = _nn_errno()
	if errno != 0
		throw(NanomsgError(context, errno))
	end
end

# Query the names and values of nanomsg symbols
_nn_symbol(i::Cint, value::Ptr{UInt8}) = ccall((:nn_symbol, LIB), Ptr{UInt8}, (Cint,Ptr{Cint}), i, value)

# Query properties of nanomsg symbols
function _nn_symbol_info(i::Cint)
	buflen = sizeof(_NNSymbolProperties)
	buf = Array{UInt8}(undef, buflen)

	r = ccall((:nn_symbol_info, LIB), Cint, (Cint,Ptr{UInt8},Csize_t), i, buf, buflen)

	if r == 0
		return nothing
	end

	if r != buflen
		throw(NanomsgError("Failed to query symbol info: " * r))
	end

	ptr = convert(Ptr{_NNSymbolProperties}, pointer(buf))
	unsafe_load(ptr)
end

# Start a device
_nn_device(s1::Cint, s2::Cint) = ccall((:nn_device, LIB), Cint, (Cint,Cint), s1, s2)

# Notify all sockets about process termination
_nn_term() = ccall((:nn_term, LIB), Nothing, ())

function j_nn_load_symbols()
	symbols = Dict{Cint, Dict{Cint, AbstractString}}()
	index::Cint = 0
	while true
		value = _nn_symbol_info(index)
		if value == nothing
			break
		end

		entry = get(symbols, value.ns, Dict{Cint, AbstractString}())
		entry[value.value] = unsafe_string(value.name)
		symbols[value.ns] = entry
		index = index + 1
	end

	symbols
end

macro load_symbols()
	blk = quote
	end

	symbols = CSymbols.J_NN_MAP
	ns = symbols[0]
	rstr = string("")
	for (v,k) in ns
		rstr = string(rstr, string("$k=$v\n"))
		ks = Symbol(k)
		push!(blk.args, Expr(:module, false, esc(ks::Symbol), Expr(:begin)))

		if v == 0
			# Namespace itself, skip as the constants will appear later
			continue
		end

		for (ev, ek) in symbols[v]
			rstr = string(rstr, string("\t$ek=$ev\n"))
			eks = Symbol(ek)
			push!(blk.args, :(const $(esc(eks)) = $ev))
		end
	end

	push!(blk.args, :(const $(Expr(:escape, :J_NN_ALL)) = $rstr))
	#println(blk)
	push!(blk.args, :nothing)
	blk.head = :toplevel
	return blk
end

# This module is dynamically loaded with constants from the
# nanomg library. Refer to the official docs for a list
baremodule CSymbols
	using Base
	using Nanomsg: j_nn_load_symbols
	using Nanomsg: @load_symbols

	const J_NN_MAP = j_nn_load_symbols()

	const NN_MSG = ~convert(Csize_t, 0)
	const NN_NO_FLAG = convert(Cint, 0)
	const NN_DONTWAIT = convert(Cint, 1)
	@load_symbols()
end

end
