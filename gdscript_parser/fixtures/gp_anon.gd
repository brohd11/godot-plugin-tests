@tool
extends RefCounted
## Fixture: mirrors caret_context.gd - a script with NO class_name whose inner classes are only
## reachable through a caller-side preload const. That combination (no global name + a bare inner
## class, not a const alias) is what the new_ins completion asks access.gd for.

@warning_ignore_start("unused_parameter", "unused_variable", "standalone_expression")

class Payload:
	var v := 0

class Outer:
	class Deep:
		var v := 0

func make() -> Payload:
	return Payload.new()

func make_deep() -> Outer.Deep:
	return Outer.Deep.new()
