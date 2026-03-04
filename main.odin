package main

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

main :: proc() {
	template, err := compile_template("template.html")
	if err != nil {
		fmt.println(err)
		os.exit(1)
	}

	data := struct {
		title: string,
		body:  string,
	} {
		title = "The Title",
		body  = "The Body",
	}

	rendered := render_template(&template, &data)
	fmt.println(rendered)
}

compile_template :: proc(path: string) -> (template: Template, err: Template_Error) {
	source, ok := os.read_entire_file(path)
	if !ok do return template, .File_Error

	template.source = string(source)

	tokenizer := Tokenizer {
		source = template.source,
	}

	instructions := make([dynamic]Instruction)

	token_loop: for {
		token, err := next_token(&tokenizer)
		if err != nil {
			fmt.println(err)
			return
		}

		instruction := Instruction{}

		switch token.kind {
		case .EOF:
			break token_loop
		case .Text:
			instruction.kind = .Static
			instruction.text = token.text
		case .Variable:
			instruction.kind = .Slot
			path := make([]string, 1)
			path[0] = token.text
			instruction.path = path
		}

		append(&instructions, instruction)
	}

	template.instructions = instructions[:]

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

render_template :: proc(template: ^Template, data: any) -> string {
	b := strings.builder_make()

	for instruction in template.instructions {
		switch instruction.kind {
		case .Static:
			strings.write_string(&b, instruction.text)
		case .Slot:
			value := resolve_field(data, instruction.path)
			if str, ok := value.(string); ok {
				strings.write_string(&b, str)
			} else if value != nil {
				fmt.sbprint(&b, value)
			}
		}
	}

	return strings.to_string(b)
}

resolve_field :: proc(data: any, path: []string) -> any {
	current := data

	for name in path {
		if current == nil do break
		if reflect.is_pointer(type_info_of(current.id)) {
			current = reflect.deref(current)
		}
		current = reflect.struct_field_value_by_name(current, name)
	}

	return current
}

@(test)
test_resolve_field :: proc(t: ^testing.T) {
	Data :: struct {
		info: Info,
		ptr:  ^Info,
	}
	Info :: struct {
		name: string,
	}
	data: Data = {
		info = {name = "dodi"},
		ptr = &{name = "dido"},
	}

	testing.expect_value(t, resolve_field(data, {"info", "name"}).(string), "dodi")
	testing.expect_value(t, resolve_field(data, {"info"}).(Info), data.info)
	testing.expect_value(t, resolve_field(data, {}).(Data), data)

	testing.expect_value(t, resolve_field(data, {"ptr", "name"}).(string), "dido")
	testing.expect_value(t, resolve_field(data, {"ptr"}).(^Info), data.ptr)
}

Template_Error :: union {
	File_Error,
	Tokenizer_Error,
}

File_Error :: enum {
	File_Error,
}

Template :: struct {
	source:       string,
	instructions: []Instruction,
}

Tokenizer_Error :: enum {
	Unclosed_Tag,
}


Tokenizer :: struct {
	source: string,
	pos:    int,
}

Token_Kind :: enum {
	EOF = 0,
	Text,
	Variable,
}

Token :: struct {
	kind: Token_Kind,
	text: string,
}

Instruction :: struct {
	kind: Instruction_Kind,
	text: string,
	path: []string,
}

Instruction_Kind :: enum {
	Static,
	Slot,
}
