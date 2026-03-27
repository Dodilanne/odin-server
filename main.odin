package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/posix"

import "./html"
import "./http"

server: http.Server

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer if len(track.allocation_map) > 0 {
			fmt.println()
			for _, v in track.allocation_map {
				fmt.printf("%v Leaked %v bytes.\n", v.location, v.size)
			}
		} else {
			fmt.println("\nNo leaks.")
		}
	}


	opts: http.Options
	flags.parse_or_exit(&opts, os.args)
	if opts.port <= 0 do opts.port = 8080

	server.thread_data = &http.Thread_Data{opts = &opts}

	posix.signal(.SIGINT, proc "cdecl" (_: posix.Signal) {
		context = runtime.default_context()
		server.quit = true
	})

	err := http.run(&server)

	if err != nil {
		fmt.println(err)
		os.exit(1)
	}
}

run_app :: proc() -> (err: App_Error) {
	template := html.compile("template.html") or_return
	defer html.delete_template(&template)

	data := Page_Data {
		title       = "The Title",
		body        = "The Body",
		show_footer = 1,
		people      = {
			{info = &{name = "dodi", age = 27}, parents = {"mj", "eric"}},
			{info = &{name = "alex", age = 24}},
		},
	}

	rendered := html.render(&template, &data) or_return
	defer delete(rendered)

	fmt.println(rendered)

	return
}

App_Error :: union {
	html.Compile_Error,
	html.Render_Error,
}

Page_Data :: struct {
	title:        string,
	body:         string,
	show_footer:  int,
	default_body: string,
	people:       []struct {
		info:    ^struct {
			name: string,
			age:  int,
		},
		parents: []string,
	},
}
