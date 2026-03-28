package http

import "core:strings"

Request :: struct {
	method:    Method,
	path:      [16]string,
	path_len:  u8,
	query:     [16][2]string,
	query_len: u8,
}

Method :: enum {
	Option,
	Get,
	Post,
}

Parse_Request_Err :: enum {
	None,
	Invalid_Method,
	Missing_Method,
	Invalid_Path,
	Missing_Path,
	Invalid_Query,
	Multiple_Queries,
}

parse_request :: proc(str: string) -> (request: Request, err: Parse_Request_Err) {
	str_it := str
	parser := Parser{&str_it}

	parse_method(&parser, &request) or_return
	parse_path_and_query(&parser, &request) or_return

	return
}

@(private = "file")
parse_method :: proc(parser: ^Parser, request: ^Request) -> (err: Parse_Request_Err) {
	field, ok := strings.fields_iterator(parser.it)
	if !ok do return .Missing_Method

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
parse_path_and_query :: proc(parser: ^Parser, request: ^Request) -> (err: Parse_Request_Err) {
	field, ok := strings.fields_iterator(parser.it)
	if !ok do return .Missing_Path

	path, _ := strings.split_iterator(&field, "?")

	for chunk in strings.split_iterator(&path, "/") {
		if len(chunk) == 0 do continue // handle leading slash
		request.path[request.path_len] = chunk
		request.path_len += 1
	}

	query, has_query := strings.split_iterator(&field, "?")
	if !has_query do return

	next_query, has_next_query := strings.split_iterator(&field, "?")
	if has_next_query do return .Multiple_Queries

	for chunk in strings.split_iterator(&query, "&") {
		chunk_it := chunk
		key, has_value := strings.split_iterator(&chunk_it, "=")
		if !has_value do return .Invalid_Query

		request.query[request.query_len] = {key, chunk_it}
		request.query_len += 1
	}

	return
}

@(private = "file")
Parser :: struct {
	it: ^string,
}
