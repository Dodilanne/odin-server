package http

import "core:strings"

Request :: struct {
	method: Method,
	path:   []string,
	query:  map[string]string,
}

Method :: enum {
	Option,
	Get,
	Post,
}

Parse_Request_Err :: enum {
	None,
	Invalid_Method,
}

parse_request :: proc(str: ^string) -> (request: Request, err: Parse_Request_Err) {
	parser := Parser{str}

	parse_method(&parser, &request) or_return

	return
}

@(private = "file")
parse_method :: proc(parser: ^Parser, request: ^Request) -> (err: Parse_Request_Err) {
	field, ok := strings.fields_iterator(parser.str)
	if !ok do return .Invalid_Method

	switch field {
	case "OPTION":
		request.method = .Option
	case "GET":
		request.method = .Get
	case "POST":
		request.method = .Post
	case:
		err = .Invalid_Method
	}
	return
}

@(private = "file")
Parser :: struct {
	str: ^string,
}
