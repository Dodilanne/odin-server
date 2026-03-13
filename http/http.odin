package http

import "base:runtime"
import "core:container/xar"
import "core:flags"
import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"

Options :: struct {
	port: int `usage:"listen port (default: 8080)"`,
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args)
	if opts.port <= 0 do opts.port = 8080

	server := Server {
		thread_data = &Thread_Data{opts = &opts},
	}

	if err := run(&server); err != nil {
		fmt.println(err)
		os.exit(1)
	}
}

Thread_Data :: struct {
	opts: ^Options,
	// error is populated by the thread itself: errors are handled by the orchestrator after all threads exit.
	err:  Thread_Error,
}

Thread_Error :: union #shared_nil {
	nbio.General_Error,
	net.Network_Error,
	net.Accept_Error,
	net.Recv_Error,
	net.Send_Error,
	net.Create_Socket_Error,
	net.Bind_Error,
	runtime.Allocator_Error,
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

run :: proc(server: ^Server) -> (err: Thread_Error) {
	nbio.acquire_thread_event_loop() or_return
	defer nbio.release_thread_event_loop()

	socket := nbio.listen_tcp({nbio.IP4_Any, server.thread_data.opts.port}) or_return
	server.socket = socket

	nbio.accept_poly(socket, server, on_accept)

	nbio.run() or_return

	return server.thread_data.err
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

	fmt.printfln("new conn")
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
