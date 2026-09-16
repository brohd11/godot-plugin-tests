extends SceneTree
## Scope inside var-assigned lambdas. Resolution must see the whole stack: a lambda's args and locals
## shadow the same names in outer lambdas and the function, and fall out of scope where it ends.
##
##     Godot --headless --path . --script res://tests/gdscript_parser/lambda_scope_test.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser
const LspSupport = preload("res://tests/gdscript_parser/lsp_support.gd")
const Keys = GDScriptParser.Keys

const FIXTURE := "res://tests/gdscript_parser/fixtures/gp_lambda_scope.gd"

# local var -> expected resolved type
const CASES := {
	"in_f_a": "Vector2",           # lambda arg shadows the func arg
	"in_f_b": "String",            # captured func arg
	"in_f_local": "Color",         # captured func local
	"in_f_shadowed": "String",     # captured func local (GDScript forbids a lambda local shadowing it)
	"in_g_c": "float",             # inner lambda arg shadows the outer lambda's
	"in_g_a": "Vector2",           # outer lambda arg; terminal in g (seeded scope path)
	"after_g_c": "Node$$INS",      # inner arg out of scope again; terminal in f
	"after_f_a": "int",            # lambda arg out of scope
	"after_f_shadowed": "String",  # lambda local out of scope
	"in_member_a": "Node2D$$INS",  # member lambda in the class body
}
# [expression, resolved on the line of this var, expected] - ClassData directly, no seeded scope
const DIRECT := [
	["a", "in_f_a", "Vector2"],
	["c", "in_g_c", "float"],
	["c", "after_g_c", "Node$$INS"],
	["a", "after_f_a", "int"],
	["a", "in_member_a", "Node2D$$INS"],
]


func _init() -> void:
	var res := run_tests()
	print("\n".join(res.output))
	quit(1 if res.result > 0 else 0)


static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


static func _run(out: Array) -> int:
	_ensure_global_class_registry()
	var native := LspSupport.available()
	var modes: Array = [false, true] if native else [false]
	if not native:
		out.append("  " + LspSupport.skip_line("Lambda Scope native mode"))
	var failures := 0
	for use_native in modes:
		failures += _run_mode(out, use_native, "native" if use_native else "plain-text")
	out.append("")
	if failures == 0:
		out.append("LAMBDA SCOPE: ALL PASS")
	else:
		out.append("LAMBDA SCOPE: %d FAILURE(S)" % failures)
	return failures


static func _run_mode(out: Array, use_native: bool, label: String) -> int:
	var f := 0
	var parser := _make_parser(use_native)
	if use_native and not LspSupport.engaged(parser):
		return _expect(out, false, "%s: native backend requested but the parse fell back to plain text" % label)
	var class_obj = parser.get_class_object("")
	var lines: PackedStringArray = (load(FIXTURE) as GDScript).source_code.split("\n")

	for var_name in CASES:
		var line := _find_var_line(lines, var_name)
		var owner = class_obj.get_lambda_at_line(line)
		if owner == null:
			owner = class_obj.get_function(class_obj.get_function_at_line(line))
		if owner == null:
			f += _expect(out, false, "%s: no function or lambda owns '%s' (line %d)" % [label, var_name, line])
			continue
		owner.map_variables()
		var key := "%s-%s-%s" % [var_name, line, lines[line].find("var ")]
		var got: String = owner.get_local_var_type(key)
		f += _expect(out, got == CASES[var_name], "%s: %s -> '%s', expected '%s' (owner locals %s)"
			% [label, var_name, got, CASES[var_name], owner.local_vars.keys()])

	for check in DIRECT:
		var got: String = parser.resolve_expression_to_type(check[0], _find_var_line(lines, check[1]))
		f += _expect(out, got == check[2], "%s: '%s' at %s -> '%s', expected '%s'" % [label, check[0], check[1], got, check[2]])

	# layered scope keeps captured names, owning vars and args, and nothing declared later
	var scope: Dictionary = class_obj.get_in_scope_vars_at_line(_find_var_line(lines, "in_g_c"))
	for expected in ["b", "outer_local", "f", "g", "a", "c", "shadowed", "in_f_a"]:
		f += _expect(out, scope.has(expected), "%s: scope inside g missing '%s' %s" % [label, expected, scope.keys()])
	f += _expect(out, not scope.has("after_g_c") and not scope.has("after_f_a"), "%s: scope inside g has later locals %s" % [label, scope.keys()])
	f += _expect(out, class_obj.get_lambda_at_line(_find_var_line(lines, "after_f_a")) == null, "%s: lambda found after f ends" % label)

	if f == 0:
		out.append("  PASS  lambda scope (%s)" % label)
	return f


static func _find_var_line(lines: PackedStringArray, var_name: String) -> int:
	for i in lines.size():
		if lines[i].strip_edges().begins_with("var %s " % var_name):
			return i
	return -1


static func _expect(out: Array, condition: bool, message: String) -> int:
	if condition:
		return 0
	out.append("  FAIL  " + message)
	return 1


static func _make_parser(use_native: bool) -> GDScriptParser:
	var parser := GDScriptParser.new()
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.set_use_native_backend(use_native) # before parse(); forces the parse path under test
	parser.active_parser = parser
	var script: GDScript = load(FIXTURE)
	parser.set_current_script(script)
	parser.set_source_code(script.source_code)
	parser.parse()
	return parser


static func _ensure_global_class_registry() -> void:
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()
