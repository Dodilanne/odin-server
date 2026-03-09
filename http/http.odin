package http

import "core:flags"
import "core:fmt"
import "core:os"
import si "core:sys/info"
import "core:thread"
import "core:time"

Options :: struct {
	threads: int `usage:"number of worker threads (0 = use all cores)"`,
	port:    int `usage:"listen port (default: 8080)"`,
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args)
	if opts.threads <= 0 do opts.threads = si.cpu.physical_cores
	if opts.port <= 0 do opts.port = 8080

	threads := make([]^thread.Thread, opts.threads)
	defer delete(threads)

	for i in 0 ..< opts.threads {
		if t := thread.create(worker); t != nil {
			t.init_context = context
			t.user_index = i
			threads[i] = t
			thread.start(t)
		}
	}

	fmt.println("waiting for threads to finish")

	thread.join_multiple(..threads)

	fmt.println("done")
}

worker :: proc(t: ^thread.Thread) {
	fmt.printfln("worker %d started", t.user_index)
	time.sleep(time.Duration(t.user_index) * time.Second)
	fmt.printfln("worker %d done", t.user_index)
}
