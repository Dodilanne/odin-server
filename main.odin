package main

import "core:fmt"
import "core:mem"
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
		title:        string,
		body:         string,
		show_footer:  int,
		default_body: string,
	} {
		title       = "The Title",
		body        = "The Body",
		show_footer = 1,
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

	block_stack := make([dynamic]Block_Stack_Entry, 16)
	defer delete(block_stack)

	instructions := make([dynamic]Instruction)

	token_loop: for {
		token := get_next_token(&tokenizer) or_return

		instruction: Maybe(Instruction)

		switch token.kind {
		case .EOF:
			break token_loop
		case .Text:
			instruction = Instruction {
				kind = .Static,
				text = token.text,
			}
		case .Open_Tag:
			next_token := get_next_token(&tokenizer) or_return

			if next_token.kind == .Text {
				close_token := get_next_token(&tokenizer) or_return
				if close_token.kind != .Close_Tag {
					err = .Missing_Close_Tag
					return
				}

				instruction = Instruction {
					kind = .Slot,
					path = strings.split(next_token.text, ".") or_return,
				}

				break
			}

			if next_token.kind == .Open_If {
				next_token = get_next_token(&tokenizer) or_return

				instr_kind: Instruction_Kind

				if next_token.kind == .Not {
					instr_kind = .If_Truthy
					next_token = get_next_token(&tokenizer) or_return
				} else {
					instr_kind = .If_Falsy
				}

				if next_token.kind != .Text {
					err = .Missing_Tag_Body
					return
				}

				close_token := get_next_token(&tokenizer) or_return
				if close_token.kind != .Close_Tag {
					err = .Missing_Close_Tag
					return
				}

				instruction = Instruction {
					kind = instr_kind,
					path = strings.split(next_token.text, ".") or_return,
				}

				append(&block_stack, Block_Stack_Entry{kind = .If, idx = len(instructions)})


				break
			}


			if next_token.kind == .Else {
				close_token := get_next_token(&tokenizer) or_return
				if close_token.kind != .Close_Tag {
					err = .Missing_Close_Tag
					return
				}

				block, exists := pop_safe(&block_stack)
				if !exists {
					err = .Missing_Open_Tag
					return
				}
				if block.kind != .If {
					err = .Invalid_Token
					return
				}

				instructions[block.idx].jump = len(instructions) + 1

				instruction = Instruction {
					kind = .Jump,
				}

				append(&block_stack, Block_Stack_Entry{kind = .Else, idx = len(instructions)})

				break
			}

			if next_token.kind == .Close_If {
				close_token := get_next_token(&tokenizer) or_return
				if close_token.kind != .Close_Tag {
					err = .Missing_Close_Tag
					return
				}

				block, exists := pop_safe(&block_stack)
				if !exists {
					err = .Missing_Open_Tag
					return
				}

				instructions[block.idx].jump = len(instructions)

				break
			}
		case .Close_Tag:
		case .Open_If:
		case .Not:
		case .Else:
		case .Close_If:
			err = .Invalid_Token
			return
		}

		if instruction, ok := instruction.?; ok {
			append(&instructions, instruction)
		}
	}

	template.instructions = instructions[:]

	return
}

get_next_token :: proc(t: ^Tokenizer) -> (token: Token, err: Tokenizer_Error) {
	token = do_get_next_token(t) or_return
	t.prev = &token
	return
}


do_get_next_token :: proc(t: ^Tokenizer) -> (token: Token, err: Tokenizer_Error) {
	if t.pos >= len(t.source) do return

	if t.prev != nil && t.prev.kind == .Open_If && t.source[t.pos] == '!' {
		token.kind = .Not
		t.pos += 1
		return
	}

	rest := t.source[t.pos:]

	if strings.has_prefix(rest, "{{") {
		token.kind = .Open_Tag
		t.pos += 2
		return
	}

	if strings.has_prefix(rest, "}}") {
		token.kind = .Close_Tag
		t.pos += 2
		return
	}

	if strings.has_prefix(rest, "#if ") {
		token.kind = .Open_If
		t.pos += 4
		return
	}

	if strings.has_prefix(rest, ":else") {
		token.kind = .Else
		t.pos += 5
		return
	}

	if strings.has_prefix(rest, "/if") {
		token.kind = .Close_If
		t.pos += 3
		return
	}

	start := t.pos
	for t.pos < len(t.source) {
		rest = t.source[t.pos:]
		if strings.has_prefix(rest, "{{") || strings.has_prefix(rest, "}}") {
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

	ip := 0
	for ip < len(template.instructions) {
		instruction := template.instructions[ip]

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
		case .Jump:
			ip = instruction.jump
			continue
		case .If_Truthy:
			value := resolve_field(data, instruction.path)
			if is_truthy(value) {
				ip = instruction.jump
				continue
			}
		case .If_Falsy:
			value := resolve_field(data, instruction.path)
			if !is_truthy(value) {
				ip = instruction.jump
				continue
			}
		}

		ip += 1
	}

	return strings.to_string(b)
}

is_truthy :: proc(v: any) -> bool {
	if v == nil do return false

	val := v
	if reflect.is_pointer(type_info_of(val.id)) {
		ptr := (^rawptr)(val.data)^
		if ptr == nil do return false
		val = reflect.deref(val)
	}

	ti := reflect.type_info_base(type_info_of(val.id))

	#partial switch info in ti.variant {
	case reflect.Type_Info_Boolean:
		return (^bool)(val.data)^
	case reflect.Type_Info_Integer:
		n, ok := reflect.as_i64(val)
		return ok && n != 0
	case reflect.Type_Info_Float:
		n, ok := reflect.as_f64(val)
		return ok && n != 0
	case reflect.Type_Info_String:
		return len((^string)(val.data)^) > 0
	case reflect.Type_Info_Slice:
		raw := (^mem.Raw_Slice)(val.data)^
		return raw.len > 0
	case reflect.Type_Info_Dynamic_Array:
		raw := (^mem.Raw_Dynamic_Array)(val.data)^
		return raw.len > 0
	}

	return true
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
	mem.Allocator_Error,
}

File_Error :: enum {
	File_Error,
}

Template :: struct {
	source:       string,
	instructions: []Instruction,
}

Tokenizer_Error :: enum {
	Missing_Open_Tag,
	Missing_Close_Tag,
	Missing_Tag_Body,
	Invalid_Token,
}


Tokenizer :: struct {
	source: string,
	pos:    int,
	prev:   ^Token,
}

Token_Kind :: enum {
	EOF = 0,
	Text,
	Open_Tag,
	Close_Tag,
	Not,
	Open_If,
	Else,
	Close_If,
}

Token :: struct {
	kind: Token_Kind,
	text: string,
}

Instruction :: struct {
	kind: Instruction_Kind,
	text: string,
	path: []string,
	jump: int,
}

Instruction_Kind :: enum {
	Static,
	Slot,
	If_Truthy,
	If_Falsy,
	Jump,
}

Block_Stack_Entry :: struct {
	kind: enum {
		If,
		Else,
	},
	idx:  int,
}
