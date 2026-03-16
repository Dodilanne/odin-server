package http

import "core:fmt"
Request :: struct {
	method: Method,
}

Method :: enum {
	Invalid,
	Option,
	Get,
	Post,
}

Parse_Request_Err :: enum {
	Invalid_Method,
}

parse_request :: proc(data: []byte) -> (req: Request, err: Parse_Request_Err) {
	cursor := 0
	for true {
		if data[cursor] == ' ' {
			break
		}
		cursor += 1
	}

	method_str := string(data[:cursor])
	fmt.printfln("method: %s", method_str)

	req.method = parse_method(method_str)
	if req.method == .Invalid {
		err = .Invalid_Method
		return
	}

	return
}

parse_method :: proc(str: string) -> Method {
	switch str {
	case "OPTION":
		return .Option
	case "GET":
		return .Get
	case "POST":
		return .Post
	case:
		return .Invalid
	}
}
