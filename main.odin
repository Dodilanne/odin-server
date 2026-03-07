package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

main :: proc() {
	err := run_app()
	if err != nil {
		fmt.println(err)
		os.exit(1)
	}
}

run_app :: proc() -> (err: App_Error) {
	template := compile_template("template.html") or_return

	data := struct {
		title:        string,
		body:         string,
		show_footer:  int,
		default_body: string,
		names:        []string,
	} {
		title       = "The Title",
		body        = "The Body",
		show_footer = 1,
		names       = {"dodi", "juju", "alex"},
	}

	rendered := render_template(&template, &data) or_return
	fmt.println(rendered)

	return
}

compile_template :: proc(path: string) -> (template: Template, err: Compile_Error) {
	source, ok := os.read_entire_file(path)
	if !ok do return template, .File_Error

	template.source = string(source)

	tokenizer := Tokenizer {
		source = template.source,
	}

	block_stack := make([dynamic]Block_Stack_Entry, 16)
	defer delete(block_stack)

	instructions := make([dynamic]Instruction)
	strip_next_static := false

	token_loop: for {
		token := get_next_token(&tokenizer) or_return

		instruction: Maybe(Instruction)

		#partial switch token.kind {
		case .EOF:
			break token_loop
		case .Text:
			text := token.text

			if strip_next_static {
				strip_next_static = false
				text = strip_whitespace(text)
			}

			instruction = Instruction {
				kind = .Static,
				text = text,
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
					path = split_path(next_token.text) or_return,
				}

				break
			}


			#partial switch next_token.kind {
			case .Open_If:
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
					path = split_path(next_token.text) or_return,
				}

				append(&block_stack, Block_Stack_Entry{kind = .If, idx = len(instructions)})
			case .Else:
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
			case .Close_If:
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
			case .Open_Each:
				next_token = get_next_token(&tokenizer) or_return
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
					kind = .Begin_Each,
					path = split_path(next_token.text) or_return,
				}

				append(&block_stack, Block_Stack_Entry{kind = .Each, idx = len(instructions)})
			case .Close_Each:
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
				if block.kind != .Each {
					err = .Invalid_Token
					return
				}

				instructions[block.idx].jump = len(instructions) + 1

				instruction = Instruction {
					kind = .End_Each,
					jump = block.idx,
				}
			case:
				err = .Invalid_Token
				return
			}

			strip_control_flow_line(&instructions)
			strip_next_static = true
		case:
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

split_path :: proc(path: string) -> ([]string, mem.Allocator_Error) {
	trimmed := strings.trim_prefix(path, ".")
	if trimmed == "" do return {}, nil
	return strings.split(trimmed, ".")
}

strip_whitespace :: proc(text: string) -> string {
	pos := 0
	for pos < len(text) && (text[pos] == ' ' || text[pos] == '\t') {
		pos += 1
	}
	if pos < len(text) && text[pos] == '\n' {
		return text[pos + 1:]
	}
	return text
}

strip_control_flow_line :: proc(instructions: ^[dynamic]Instruction) {
	if len(instructions) == 0 {
		return
	}

	last := &instructions[len(instructions) - 1]
	if last.kind != .Static {
		return
	}

	text := last.text
	pos := len(text)
	for pos > 0 && (text[pos - 1] == ' ' || text[pos - 1] == '\t') {
		pos -= 1
	}
	if pos == 0 || text[pos - 1] == '\n' {
		last.text = text[:pos]
	}
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

	if strings.has_prefix(rest, "#each ") {
		token.kind = .Open_Each
		t.pos += 6
		return
	}

	if strings.has_prefix(rest, "/each") {
		token.kind = .Close_Each
		t.pos += 5
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

render_template :: proc(
	template: ^Template,
	root_data: any,
) -> (
	rendered: string,
	err: Render_Error,
) {
	b := strings.builder_make()

	stack := [8]any{}
	stack[0] = root_data
	stack_idx := 0

	ip := 0
	for ip < len(template.instructions) {
		instruction := &template.instructions[ip]

		#partial switch instruction.kind {
		case .Static:
			strings.write_string(&b, instruction.text)
		case .Slot:
			value := resolve_field(stack[stack_idx], instruction.path)
			if str, ok := value.(string); ok {
				strings.write_string(&b, str)
			} else if value != nil {
				fmt.sbprint(&b, value)
			}
		case .Jump:
			ip = instruction.jump
			continue
		case .If_Truthy:
			value := resolve_field(stack[stack_idx], instruction.path)
			if is_truthy(value) {
				ip = instruction.jump
				continue
			}
		case .If_Falsy:
			value := resolve_field(stack[stack_idx], instruction.path)
			if !is_truthy(value) {
				ip = instruction.jump
				continue
			}
		case .Begin_Each:
			data := stack[stack_idx]
			value := resolve_field(data, instruction.path)

			elem := get_iterable_element(value, instruction.it)
			if elem == nil {
				instruction.it = 0
				ip = instruction.jump
				continue
			}

			stack_idx += 1
			if stack_idx == len(stack) {
				err = .Max_Nested_Each_Reached
				return
			}

			stack[stack_idx] = elem

			instruction.it += 1
		case .End_Each:
			ip = instruction.jump
			stack_idx -= 1
			continue
		}

		ip += 1
	}

	rendered = strings.to_string(b)
	return
}

get_iterable_element :: proc(v: any, idx: int) -> any {
	if v == nil do return nil

	val := v
	if reflect.is_pointer(type_info_of(val.id)) {
		ptr := (^rawptr)(val.data)^
		if ptr == nil do return nil
		val = reflect.deref(val)
	}

	ti := reflect.type_info_base(type_info_of(val.id))

	#partial switch info in ti.variant {
	case reflect.Type_Info_String:
		str := (^string)(val.data)^
		if idx > len(str) - 1 do return nil
		return str[idx]
	case reflect.Type_Info_Slice:
		raw := (^mem.Raw_Slice)(val.data)^
		if idx > raw.len - 1 do return nil
		elem_ptr := rawptr(uintptr(raw.data) + uintptr(idx * info.elem_size))
		return any{elem_ptr, info.elem.id}
	case reflect.Type_Info_Dynamic_Array:
		raw := (^mem.Raw_Dynamic_Array)(val.data)^
		if idx > raw.len - 1 do return nil
		elem_ptr := rawptr(uintptr(raw.data) + uintptr(idx * info.elem_size))
		return any{elem_ptr, info.elem.id}
	case reflect.Type_Info_Array:
		if idx > info.count - 1 do return nil
		elem_ptr := rawptr(uintptr(val.data) + uintptr(idx * info.elem_size))
		return any{elem_ptr, info.elem.id}
	}

	return nil
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
	if len(path) == 0 {
		return data
	}

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

App_Error :: union {
	Compile_Error,
	Render_Error,
}

Compile_Error :: union {
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
	Open_Each,
	Close_Each,
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
	it:   int,
}

Instruction_Kind :: enum {
	Static,
	Slot,
	If_Truthy,
	If_Falsy,
	Begin_Each,
	End_Each,
	Jump,
}

Block_Stack_Entry :: struct {
	kind: enum {
		If,
		Else,
		Each,
	},
	idx:  int,
}

Render_Error :: enum {
	Max_Nested_Each_Reached,
}
