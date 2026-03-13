package html

import "core:mem"
import "core:os"
import "core:strings"

Compile_Error :: union {
	File_Error,
	Tokenizer_Error,
	mem.Allocator_Error,
	os.Error,
}

compile :: proc(path: string) -> (template: Template, err: Compile_Error) {
	source := os.read_entire_file_from_path(path, context.allocator) or_return

	template.source = string(source)

	tokenizer := Tokenizer {
		source = template.source,
	}

	block_stack := make([dynamic]Block_Stack_Entry, 0, 16)
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
					instr_kind = .If_Falsy
					next_token = get_next_token(&tokenizer) or_return
				} else {
					instr_kind = .If_Truthy
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

@(private = "file")
split_path :: proc(path: string) -> ([]string, mem.Allocator_Error) {
	trimmed := strings.trim_prefix(path, ".")
	if trimmed == "" do return {}, nil
	return strings.split(trimmed, ".")
}

@(private = "file")
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

@(private = "file")
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
	if pos > 0 && text[pos - 1] == '\n' {
		last.text = text[:pos]
	}
}

@(private = "file")
get_next_token :: proc(t: ^Tokenizer) -> (token: Token, err: Tokenizer_Error) {
	token = do_get_next_token(t) or_return
	t.prev = token
	return
}


@(private = "file")
do_get_next_token :: proc(t: ^Tokenizer) -> (token: Token, err: Tokenizer_Error) {
	if t.pos >= len(t.source) do return

	if t.prev.kind == .Open_If && t.source[t.pos] == '!' {
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
		c := t.source[t.pos]
		if (c == '{' || c == '}') && t.pos + 1 < len(t.source) && t.source[t.pos + 1] == c {
			break
		}
		t.pos += 1
	}

	token.kind = .Text
	token.text = t.source[start:t.pos]

	return
}

@(private = "file")
Block_Stack_Entry :: struct {
	kind: enum {
		If,
		Else,
		Each,
	},
	idx:  int,
}

@(private = "file")
File_Error :: enum {
	File_Error,
}

@(private = "file")
Tokenizer_Error :: enum {
	Missing_Open_Tag,
	Missing_Close_Tag,
	Missing_Tag_Body,
	Invalid_Token,
}

@(private = "file")
Tokenizer :: struct {
	source: string,
	pos:    int,
	prev:   Token,
}

@(private = "file")
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

@(private = "file")
Token :: struct {
	kind: Token_Kind,
	text: string,
}
