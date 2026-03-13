package http

import "base:runtime"
import "core:container/xar"
import "core:flags"
import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import si "core:sys/info"
import "core:thread"

Options :: struct {
	num_threads: int `args:"name=threads" usage:"number of worker threads (0 = use all cores)"`,
	port:        int `usage:"listen port (default: 8080)"`,
}

Thread_Data :: struct {
	thread_index: int,
	opts:         ^Options,
	// error is populated by the thread itself: errors are handled by the orchestrator after all threads exit.
	err:          Thread_Error,
}

Thread_Error :: union #shared_nil {
	_Thread_Error,
	nbio.General_Error,
	net.Network_Error,
	net.Accept_Error,
	net.Recv_Error,
	net.Send_Error,
	runtime.Allocator_Error,
}

_Thread_Error :: enum {
	None = 0,
	Ouch,
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args)
	if opts.num_threads <= 0 {
		if physical, _, ok := si.cpu_core_count(); ok {
			opts.num_threads = physical
		} else {
			opts.num_threads = 1
		}
	}
	if opts.port <= 0 do opts.port = 8080

	thread_data := make([]Thread_Data, opts.num_threads)
	defer delete(thread_data)

	threads := make([]^thread.Thread, opts.num_threads)
	defer delete(threads)

	for i in 0 ..< opts.num_threads {
		thread_data[i].thread_index = i
		thread_data[i].opts = &opts
		t := thread.create_and_start_with_data(&thread_data[i], worker)
		threads[i] = t
	}

	fmt.println("waiting for threads to finish")

	thread.join_multiple(..threads)

	fmt.println("done")

	for result in thread_data {
		if result.err != nil {
			fmt.printfln("Worker %d failed with error %v", result.thread_index, result.err)
		}
	}
}

worker :: proc(ptr: rawptr) {
	data := (^Thread_Data)(ptr)

	fmt.printfln("worker %d started", data.thread_index)

	data.err = do_work(data)
	if data.err == nil {
		fmt.printfln("worker %d done", data.thread_index)
	} else {
		fmt.printfln("worker %d done with err %v", data.thread_index, data.err)
	}

}

Server :: struct {
	thread_data: ^Thread_Data,
	socket:      nbio.TCP_Socket,
	// Xar is used in favor of `[dynamic]Connection` so pointers are stable.
	connections: xar.Array(Connection, 4),
}

Connection :: struct {
	server: ^Server,
	socket: nbio.TCP_Socket,
	buf:    [50]byte,
}

do_work :: proc(data: ^Thread_Data) -> (err: Thread_Error) {
	nbio.acquire_thread_event_loop() or_return
	defer nbio.release_thread_event_loop()

	server := Server {
		thread_data = data,
	}

	socket := nbio.listen_tcp({nbio.IP4_Any, data.opts.port}) or_return
	server.socket = socket

	nbio.accept_poly(socket, &server, on_accept)

	return nbio.run()
}

on_accept :: proc(op: ^nbio.Operation, server: ^Server) {
	if err := do_accept(op, server); err != nil {
		server.thread_data.err = err
	}
}

do_accept :: proc(op: ^nbio.Operation, server: ^Server) -> (err: Thread_Error) {
	if op.accept.err != nil {
		return op.accept.err
	}

	nbio.accept_poly(server.socket, server, on_accept)

	fmt.printfln("new conn on thread %d!", server.thread_data.thread_index)
	conn := xar.push_back_elem_and_get_ptr(
		&server.connections,
		Connection{server = server, socket = op.accept.client},
	) or_return

	nbio.recv_poly(op.accept.client, {conn.buf[:]}, conn, on_recv)

	return
}

on_recv :: proc(op: ^nbio.Operation, conn: ^Connection) {
	if err := do_recv(op, conn); err != nil {
		conn.server.thread_data.err = err
	}
}

do_recv :: proc(op: ^nbio.Operation, conn: ^Connection) -> (err: Thread_Error) {
	if op.recv.err != nil {
		fmt.printfln("recv err: %v", op.recv.err)
		return op.recv.err
	}

	if op.recv.received == 0 {
		// Note: leaking connection
		fmt.println("nothing received, stopping")
		nbio.close(conn.socket)
		return
	}

	fmt.println("echoing back")
	nbio.send_poly(conn.socket, {conn.buf[:op.recv.received]}, conn, on_sent)

	return
}

on_sent :: proc(op: ^nbio.Operation, conn: ^Connection) {
	if err := do_sent(op, conn); err != nil {
		conn.server.thread_data.err = err
	}
}

do_sent :: proc(op: ^nbio.Operation, conn: ^Connection) -> (err: Thread_Error) {
	if op.send.err != nil {
		return op.send.err
	}

	fmt.println("setting up next recv")
	nbio.recv_poly(conn.socket, {conn.buf[:]}, conn, on_recv)

	return
}
