package html

Template :: struct {
	source:       string,
	instructions: []Instruction,
}

delete_template :: proc(t: ^Template) {
	for &instruction in t.instructions {
		delete(instruction.path)
	}
	delete(t.instructions)
	delete(t.source)
}

@(private)
Instruction :: struct {
	kind: Instruction_Kind,
	text: string,
	path: []string,
	jump: int,
}

@(private)
Instruction_Kind :: enum {
	Static,
	Slot,
	If_Truthy,
	If_Falsy,
	Begin_Each,
	End_Each,
	Jump,
}
