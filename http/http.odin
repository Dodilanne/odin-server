package http

import "core:flags"
import "core:fmt"
import "core:os"
import si "core:sys/info"
import "core:thread"
import "core:time"

Options :: struct {
	num_threads: int `args:"name=threads" usage:"number of worker threads (0 = use all cores)"`,
	port:        int `usage:"listen port (default: 8080)"`,
}

Thread_Result :: struct {
	thread_index: int,
	error:        Thread_Error,
}

Thread_Error :: union #shared_nil {
	_Thread_Error,
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

	thread_results := make([]Thread_Result, opts.num_threads)
	defer delete(thread_results)

	threads := make([]^thread.Thread, opts.num_threads)
	defer delete(threads)

	for i in 0 ..< opts.num_threads {
		thread_results[i].thread_index = i
		t := thread.create_and_start_with_data(&thread_results[i], worker)
		threads[i] = t
	}

	fmt.println("waiting for threads to finish")

	thread.join_multiple(..threads)

	fmt.println("done")

	for result in thread_results {
		if result.error != nil {
			fmt.printfln("Worker %d failed with error %v", result.thread_index, result.error)
		}
	}
}

worker :: proc(ptr: rawptr) {
	t := (^Thread_Result)(ptr)

	fmt.printfln("worker %d started", t.thread_index)

	t.error = do_work(t.thread_index)

	fmt.printfln("worker %d done", t.thread_index)
}

do_work :: proc(thread_index: int) -> (err: Thread_Error) {
	if thread_index == 1 {
		return .Ouch
	}

	time.sleep(time.Duration(thread_index) * time.Second)

	return
}
