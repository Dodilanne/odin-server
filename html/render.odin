package html

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import "core:testing"

Render_Error :: enum {
	Max_Nested_Each_Reached,
}

render :: proc(template: ^Template, root_data: any) -> (rendered: string, err: Render_Error) {
	b := strings.builder_make(0, len(template.source))

	iter_state := make([]int, len(template.instructions))
	defer delete(iter_state)

	stack := [8]any{}
	stack[0] = root_data
	stack_idx := 0

	ip := 0
	for ip < len(template.instructions) {
		instruction := template.instructions[ip]

		#partial switch instruction.kind {
		case .Static:
			strings.write_string(&b, instruction.text)
		case .Slot:
			value := resolve_field(stack[stack_idx], instruction.path)
			if str, ok := value.(string); ok {
				write_escaped_html(&b, str)
			} else if value != nil {
				write_escaped_html(&b, fmt.tprint(value))
			}
		case .Jump:
			ip = instruction.jump
			continue
		case .If_Truthy:
			value := resolve_field(stack[stack_idx], instruction.path)
			if !is_truthy(value) {
				ip = instruction.jump
				continue
			}
		case .If_Falsy:
			value := resolve_field(stack[stack_idx], instruction.path)
			if is_truthy(value) {
				ip = instruction.jump
				continue
			}
		case .Begin_Each:
			data := stack[stack_idx]
			value := resolve_field(data, instruction.path)

			elem := get_iterable_element(value, iter_state[ip])
			if elem == nil {
				iter_state[ip] = 0
				ip = instruction.jump
				continue
			}

			stack_idx += 1
			if stack_idx == len(stack) {
				err = .Max_Nested_Each_Reached
				return
			}

			stack[stack_idx] = elem

			iter_state[ip] += 1
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

@(private = "file")
write_escaped_html :: proc(b: ^strings.Builder, s: string) {
	for c in s {
		switch c {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case '\'':
			strings.write_string(b, "&#39;")
		case:
			strings.write_rune(b, c)
		}
	}
}

@(private = "file")
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

@(private = "file")
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
