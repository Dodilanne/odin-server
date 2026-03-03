package main

import "core:fmt"
import "core:os"

main :: proc() {
	template, err := load_template("template.html")
	if err != nil {
		fmt.println(err)
		os.exit(1)
	}
}

load_template :: proc(path: string) -> (template: Template, err: Template_Error) {
	source, ok := os.read_entire_file(path)
	if !ok do return template, .File_Error

	template.source = source

	tokenizer := Tokenizer {
		source = source,
	}

	for {
		token, err := next_token(&tokenizer)
		if err != nil {
			fmt.println(err)
			return
		}

		fmt.println()
		fmt.printfln("%v:", token.kind)
		fmt.println(string(token.text))

		if token.kind == .EOF do break
	}

	return
}

next_token :: proc(t: ^Tokenizer) -> (token: Token, err: Tokenizer_Error) {
	if t.pos >= len(t.source) do return

	if t.pos + 1 < len(t.source) && t.source[t.pos] == '{' && t.source[t.pos + 1] == '{' {
		t.pos += 2
		start := t.pos
		for t.pos + 1 < len(t.source) {
			if t.source[t.pos] == '}' && t.source[t.pos + 1] == '}' {
				token.kind = .Variable
				token.text = t.source[start:t.pos]
				t.pos += 2
				return
			}
			t.pos += 1
		}
		err = .Unclosed_Tag
		return
	}

	start := t.pos
	for t.pos < len(t.source) {
		if t.pos + 1 < len(t.source) && t.source[t.pos] == '{' && t.source[t.pos + 1] == '{' {
			break
		}
		t.pos += 1
	}

	token.kind = .Text
	token.text = t.source[start:t.pos]

	return
}

Template_Error :: union {
	File_Error,
	Tokenizer_Error,
}

File_Error :: enum {
	File_Error,
}

Template :: struct {
	source: []byte,
}

Tokenizer_Error :: enum {
	Unclosed_Tag,
}


Tokenizer :: struct {
	source: []byte,
	pos:    int,
}

Token_Kind :: enum {
	EOF = 0,
	Text,
	Variable,
}

Token :: struct {
	kind: Token_Kind,
	text: []byte,
}
