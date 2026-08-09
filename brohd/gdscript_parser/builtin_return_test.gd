@tool
extends RefCounted
## Builtin (engine) method/signal return typing, straight off BuiltInChecker - no resolve machinery.
##
## Regression guard: in extension_api.json a void method OMITS `return_value` but still carries its
## `arguments`. _get_member_type() used to fall into the signal-only `arguments` branch and type the
## call as its arg (1 arg) or "Array" (2+ args) - e.g. Control.add_theme_color_override -> "Array".
## The fix gates that branch on member_type == signals; void methods now fall through to "void".
##
##     load("res://tests/brohd/gdscript_parser/builtin_return_test.gd").run_tests()

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser
const BuiltInChecker = GDScriptParser.BuiltInChecker


## {class, member, expected} - get_func_return returns the member's resolved type string.
static func _cases() -> Array:
	return [
		# void methods that carry `arguments` (the reported bug, plus the 1-arg variant that used to
		# leak the arg type instead of "Array").
		{"class": "Control", "member": "add_theme_color_override", "expected": "void"},  # 2 args -> was "Array"
		{"class": "Node",    "member": "set_name",                 "expected": "void"},  # 1 arg  -> was "StringName"
		# real signals still type from their args - the branch the gate preserves.
		{"class": "BaseButton",       "member": "toggled",           "expected": "bool"},   # single arg
		{"class": "AnimationLibrary", "member": "animation_renamed", "expected": "Array"},  # multi arg
		# non-void method keeps its real return - guards against over-correcting to "void".
		{"class": "Node", "member": "get_child", "expected": "Node"},
	]


static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


static func _run(out: Array) -> int:
	var fails := 0
	for case in _cases():
		var got := BuiltInChecker.get_func_return(case.class, case.member)
		if got == case.expected:
			out.append("  PASS  %-24s.%-24s -> %s" % [case.class, case.member, got])
		else:
			fails += 1
			out.append("  FAIL  %-24s.%-24s expected '%s' got '%s'"
				% [case.class, case.member, case.expected, got])
	out.append("\nBUILTIN RETURN: %s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	return fails
