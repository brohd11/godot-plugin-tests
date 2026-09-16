extends SceneTree
## The metadata consumers (dict_key's `#! keys`, arg_location's `#! arg_location`) reconstruct a member
## path from the caret's symbol data and look the tag up by it. TagParser keys that metadata by the
## script whose SOURCE carries the `#!` comment - i.e. the script where the member is DECLARED.
##
## caret_context builds that path from symbol_script_path, which is resolved from the RECEIVER
## expression, so it names the script of the object being called. For an inherited method the two
## diverge (object = derived, declaration = base) and the lookup misses - the bug that surfaced in
## dict_key. `origin` already carries the declaring member, and get_function_data() resolves the
## ancestor's ParserFunc out of it, so the parser knows the right answer; only the reconstruction is
## wrong.
##
## The invariant, then: the path reconstructed from the symbol data must equal the declaring member
## path that origin already states.
##
##     Godot --headless --path . --script res://tests/gdscript_parser/declaring_script_test.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser
const Utils = GDScriptParser.Utils

const DIR := "res://tests/gdscript_parser/"
const COLLISION := DIR + "scenarios/scenario_collision.gd"
const KIT_BASE := DIR + "fixtures/gp_kit_base.gd"


## Each case: a call-site anchor, and the script the called function is DECLARED in.
static func _cases() -> Array:
	return [
		# tf_simple is declared in gp_kit_base.gd but called through a GpKitDerived instance: the
		# object's script and the declaring script diverge. This is the dict_key / arg_location bug.
		{"name": "inherited_method_via_derived", "script": COLLISION, "anchor": "\tn.tf_simple(",
			"declared_in": KIT_BASE},
		{"name": "inherited_bare_inner_arg", "script": COLLISION, "anchor": "\tn.emit(",
			"declared_in": KIT_BASE},
		# Controls: receiver script == declaring script. These pass today and must keep passing - they
		# are what makes the fix a fix rather than a swap of one wrong answer for another.
		{"name": "own_inner_class_method", "script": COLLISION, "anchor": "\tic.use_mode(",
			"declared_in": KIT_BASE + ".Inner"},
		{"name": "own_inner_class_outer_arg", "script": COLLISION, "anchor": "\tic.use_outer(",
			"declared_in": KIT_BASE + ".Inner"},
	]


# Headless entry point. quit() lives ONLY here so the static path below is safe to call from the
# editor console / aggregator without killing the editor.
func _init() -> void:
	var res := run_tests()
	print("\n".join(res.output))
	quit(1 if res.result > 0 else 0)


## Runs the suite; returns {result: fail count (0 == all good), output: report lines}.
static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


static func _run(out: Array) -> int:
	_ensure_global_class_registry()
	var fails := 0
	var ctx_cache := {}

	for case in _cases():
		var ctx = _get_ctx(ctx_cache, case.script)
		var caret := _find_caret(ctx.lines, case.anchor)
		if caret.x == -1:
			out.append("  FAIL  %s -> anchor not found: %s" % [case.name, case.anchor])
			fails += 1
			continue
		fails += _check(out, case, ctx.parser, caret)

	out.append("")
	out.append("DECLARING SCRIPT: %s" % ("ALL PASS" if fails == 0 else "%d FAILURE(S)" % fails))
	return fails


static func _check(out: Array, case: Dictionary, parser: GDScriptParser, caret: Vector2i) -> int:
	parser.code_edit.set_caret_line(caret.y)
	parser.code_edit.set_caret_column(caret.x)
	parser.reset_caret_context()
	var cc = parser.get_caret_context()

	var fcd = cc.get_function_call_data()
	if fcd == null:
		out.append("  FAIL  %s -> no function call data at the caret" % case.name)
		return 1

	var func_name: String = fcd.get_function_name()
	var origin: String = fcd.symbol_data.origin
	if not Utils.is_absolute_path(origin):
		out.append("  FAIL  %s -> origin '%s' is not a script member path" % [case.name, origin])
		return 1

	# What origin says: the declaring member, e.g. res://.../gp_kit_base.gd::tf_simple
	var declared_script: String = Utils.type_path_get_non_member(origin)
	# What the consumers rebuild from the symbol data (dict_key.gd / arg_location.gd both do this).
	var reconstructed: String = Utils.type_path_add_member(fcd.get_function_script(), func_name)
	var origin_key: String = Utils.type_path_add_member(declared_script, func_name)

	var failures := 0
	if declared_script != case.declared_in:
		out.append("  FAIL  %s -> origin names '%s' as the declaring script, expected '%s'"
			% [case.name, declared_script, case.declared_in])
		failures += 1
	if reconstructed != origin_key:
		out.append("  FAIL  %s -> reconstructed path '%s' != declaring member path '%s' (metadata lookup misses)"
			% [case.name, reconstructed, origin_key])
		failures += 1

	if failures == 0:
		out.append("  PASS  %s -> %s" % [case.name, origin_key])
	return failures


#region Harness internals ------------------------------------------------------------------

static func _get_ctx(cache: Dictionary, script_path: String) -> Dictionary:
	if not cache.has(script_path):
		cache[script_path] = {
			"parser": _make_parser(script_path),
			"lines": (load(script_path).source_code as String).split("\n"),
		}
	return cache[script_path]


static func _make_parser(script_path: String) -> GDScriptParser:
	var parser := GDScriptParser.new()
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.active_parser = parser
	parser.set_current_script(load(script_path))
	parser.set_source_code(load(script_path).source_code)
	parser.parse()
	return parser


## Caret goes just after the anchor (inside the call's parens). x == -1 if the anchor is missing.
static func _find_caret(lines: PackedStringArray, anchor: String) -> Vector2i:
	for i in lines.size():
		var col := lines[i].find(anchor)
		if col == -1:
			continue
		return Vector2i(col + anchor.length(), i)
	return Vector2i(-1, -1)


static func _ensure_global_class_registry() -> void:
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()

#endregion
