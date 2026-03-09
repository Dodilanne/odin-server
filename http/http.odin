package http

import "core:flags"
import "core:fmt"
import "core:os"
import si "core:sys/info"

Options :: struct {
	workers: int `usage:"number of worker threads (0 = use all cores)"`,
	port:    int `usage:"listen port (default: 8080)"`,
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args)
	if opts.workers <= 0 do opts.workers = si.cpu.physical_cores
	if opts.port <= 0 do opts.port = 8080

	fmt.println(opts)
}
