@tool
extends RefCounted
## Local-variable type-inference tests for the gdscript parser.
##
## Builds a GDScriptParser over scenario_inference.gd, maps the locals of infer_cases(), and asserts
## the resolved `type` of each named local. Each case names a local; the runner finds that local's
## mangled `name-line-col` key (parser_func.gd stores every local that way) and resolves it.
##
## Run it (returns {result: fail count, output: report lines}):
##     load("res://tests/gdscript_parser/inference_test.gd").run_tests()
##     load("res://tests/gdscript_parser/inference_test.gd").probe_all()   # dump every local's type
##
## IMPORTANT: a *running* editor caches the parser scripts via preloaded consts, so edits to them are
## NOT reliably hot-reloaded - use the clean-compile headless runner:
##     Godot --headless --path . --script res://tests/gdscript_parser/run_inference_headless.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser
const Keys = GDScriptParser.Keys

const DIR := "res://tests/gdscript_parser/"
const SCENARIO := DIR + "scenarios/scenario_inference.gd"
const FUNC := "infer_cases"


## Each case: the `name` of a local in infer_cases() and its `expected` resolved type. `probe: true`
## prints the resolved type without asserting (used while authoring / locking in expected strings).
##
## An optional `origin` pins type_rich.origin - a SEPARATE resolve from `type` (find_origin=true walks
## the assignment chain back to the declaring member instead of stopping at the declared type), and the
## key the completions layer looks metadata up by. It is set on the cases whose origin shape differs:
## a declaring member path (`::member##Type`), the ##Callable / ##Enum / ##Signal suffixes, an engine
## class member (`LineEdit::text_changed##Signal`), an inner-class member, a `$$INS` script path, and a
## bare type. Where the origin names a script member, the case also asserts it resolves back through
## get_member_data_from_origin() - the round-trip dict_key.gd depends on.
static func _cases() -> Array:
	return [
		# --- explicit type + iteration typing ---
		# declared `int`, but assigned InfSupport.INT_2: type stops at the hint, origin chases the const.
		{"name": "explicit_int", "expected": "int",
			"origin": "res://tests/gdscript_parser/fixtures/inf_support.gd::INT_2##int"},
		{"name": "dict_key", "expected": "String"},              # typed-dict key type
		{"name": "dict_value", "expected": "int"},               # typed-dict values() element
		# --- builtin value + index typing ---
		{"name": "color_val", "expected": "Color"},
		{"name": "chan_by_str", "expected": "float"},            # Color["r"]
		{"name": "chan_by_idx", "expected": "float"},            # Color[0]
		{"name": "html_str", "expected": "String"},
		{"name": "first_char", "expected": "String"},            # String[0]
		# --- lambda / await / signals ---
		{"name": "lambda_ref", "expected": "Callable"},
		# same declaring member, two different types: origin is the signal, type is its arg / Signal.
		{"name": "awaited_signal_arg", "expected": "int",        # await signal -> arg type
			"origin": "res://tests/gdscript_parser/scenarios/scenario_inference.gd::local_signal##int"},
		{"name": "signal_ref", "expected": "Signal",
			"origin": "res://tests/gdscript_parser/scenarios/scenario_inference.gd::local_signal##Signal"},
		{"name": "awaited_ref", "expected": "int"},              # await a Signal-valued local
		# --- builtin func as Callable + its .call() return ---
		{"name": "builtin_callable", "expected": "Callable",     # `char`
			"origin": "char##Callable"},                         # builtin: no script path to anchor to
		{"name": "builtin_ret", "expected": "String"},           # char.call()
		{"name": "callable_chain_bool", "expected": "bool"},     # Callable.bind().bind().is_null()
		# --- cross-func callable/signal chains ---
		# origin chases through the returning func to the func that was returned as a value.
		{"name": "returned_callable", "expected": "Callable",
			"origin": "res://tests/gdscript_parser/scenarios/scenario_inference.gd::funk_test##Callable"},
		# two hops: get_call() -> funk_test() -> `code.text_changed` on a LineEdit local.
		{"name": "called_signal", "expected": "Signal",
			"origin": "LineEdit::text_changed##Signal"},         # engine class member, not a res:// path
		{"name": "awaited_return", "expected": "String"},
		{"name": "returned_callable2", "expected": "Callable",
			"origin": "res://tests/gdscript_parser/scenarios/scenario_inference.gd::another_sig##Callable"},
		{"name": "called_signal2", "expected": "Signal",         # another_sig() -> InfSupport.new().sig_bool
			"origin": "res://tests/gdscript_parser/fixtures/inf_support.gd::sig_bool##Signal"},
		{"name": "awaited_bool", "expected": "bool",             # same member, awaited -> the arg type
			"origin": "res://tests/gdscript_parser/fixtures/inf_support.gd::sig_bool##bool"},
		{"name": "sig_connections", "expected": "Array"},        # Signal.get_connections()
		{"name": "typed_conns", "expected": "Array[String]"},
		# --- constructor instances + method returns + subscript-new ---
		{"name": "made_obj", "expected": "res://tests/gdscript_parser/fixtures/inf_support.gd$$INS",
			"origin": "res://tests/gdscript_parser/fixtures/inf_support.gd$$INS"}, # instance: no member tail
		{"name": "obj_string", "expected": "String",
			"origin": "res://tests/gdscript_parser/fixtures/inf_support.gd::get_string##String"},
		{"name": "static_string", "expected": "String",
			"origin": "res://tests/gdscript_parser/fixtures/inf_support.gd::static_get_string##String"},
		{"name": "subscript_new", "expected": "res://tests/gdscript_parser/fixtures/inf_support.gd$$INS"},
		{"name": "subscript_string", "expected": "String"},
		{"name": "made_signal", "expected": "Signal"},           # untyped func returning a signal
		{"name": "awaited_made", "expected": "bool"},
		# --- engine-typed local getters ---
		{"name": "got_variant", "expected": "String"},           # LineEdit.get("text") -> known prop
		{"name": "menu_callable", "expected": "Callable",
			"origin": "LineEdit::get_menu##Callable"},
		{"name": "menu", "expected": "PopupMenu$$INS"},
		{"name": "awaited_text", "expected": "String"},
		# --- user-type dict key/value ---
		# declared hint + `= {}`: origin keeps the hint rather than the empty literal (type_lookup.gd:902).
		{"name": "typed_map", "expected": "Dictionary[InfEnum, InfEnum.Nested]",
			"origin": "Dictionary[InfEnum, InfEnum.Nested]"},
		{"name": "map_key", "expected": "res://tests/gdscript_parser/fixtures/inf_enum.gd$$INS"},
		{"name": "map_val", "expected": "res://tests/gdscript_parser/fixtures/inf_enum.gd.Nested$$INS",
			"origin": "res://tests/gdscript_parser/fixtures/inf_enum.gd.Nested$$INS"}, # inner class instance
		# --- packed array element / preload const / as-cast ---
		{"name": "packed", "expected": "PackedByteArray"},
		{"name": "byte", "expected": "int"},
		{"name": "preload_const", "expected": "Color",           # preload(...).MY_COLOR
			"origin": "res://tests/gdscript_parser/fixtures/inf_enum.gd::MY_COLOR##Color"},
		{"name": "cast_obj", "expected": "res://tests/gdscript_parser/fixtures/inf_enum.gd$$INS"},
		# --- nested static enum-returning func (Callable + enum return) ---
		{"name": "nested_callable", "expected": "Callable",      # inner-class member path + ##Callable
			"origin": "res://tests/gdscript_parser/fixtures/inf_support.gd.Nested::node_test##Callable"},
		{"name": "nested_call_ret", "expected": "Node::ProcessMode##Enum",
			"origin": "Node::ProcessMode##Enum"},                # ##Enum shape
		{"name": "nested_direct", "expected": "Node::ProcessMode##Enum"},
		# --- instance value vs bare type ---
		{"name": "node_ins", "expected": "Node$$INS", "origin": "Node$$INS"},
		{"name": "node_static", "expected": "Node", "origin": "Node"},
		# --- member-shadowing local ---
		{"name": "pre_shadow_callable", "expected": "Callable",  # before shadow: the func
			"origin": "res://tests/gdscript_parser/scenarios/scenario_inference.gd::shadowed_func##Callable"},
		{"name": "shadowed_func", "expected": "String"},         # the shadowing local
		{"name": "post_shadow", "expected": "String"},           # ref after shadow -> the local
		# --- terminal local directly followed by a func decl (end-of-function boundary) ---
		{"name": "direct_terminal", "expected": "Color", "func": "terminal_before_func"},
	]


## Runs the suite; returns {result: fail count (0 == all good), output: report lines}.
static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out, false), "output": out}


## Authoring aid: force every case into probe mode and print the resolved type for each local.
static func probe_all() -> String:
	var out: Array = []
	_run(out, true)
	return "\n".join(out)


## Runs the suite in both parse modes so the plain-text path (where the terminal-var map fix lives)
## and the tree-sitter path are both covered. Sums the failure counts.
static func _run(out: Array, probe_all_mode := false) -> int:
	var fails := 0
	# Plain-text parse path - always runnable, and where the map_variables terminal-line fix applies.
	fails += _run_mode(out, false, probe_all_mode)
	# Tree-sitter parse path - only when the GDScriptTreeSitter extension is registered.
	if ClassDB.class_exists("GDScriptTreeSitter"):
		fails += _run_mode(out, true, probe_all_mode)
	else:
		out.append("\n  (GDScriptTreeSitter not registered - tree-sitter mode skipped)")
	return fails


static func _run_mode(out: Array, use_tree_sitter: bool, probe_all_mode := false) -> int:
	_ensure_global_class_registry()
	var parser := _make_parser(SCENARIO, use_tree_sitter)
	var cobj = parser.get_class_object("")
	# Cache of mapped functions: func_name -> { fobj, name_map(plain_name -> mangled key) }.
	# Most cases target FUNC (infer_cases); a case may set `func` to target another function.
	var func_cache := {}
	var primary = _map_func(cobj, FUNC, func_cache)
	if primary.is_empty():
		out.append("[SETUP FAIL] function '%s' not found in %s" % [FUNC, SCENARIO])
		return 1

	var mode_label: String = "tree-sitter" if use_tree_sitter else "plain-text"
	out.append("\n=============== INFERENCE TESTS (%s) ===============" % mode_label)
	out.append("  locals mapped: %d" % primary.fobj.local_vars.size())

	var pass_count := 0
	var fail_count := 0
	for case in _cases():
		var name: String = case.name
		var fn: String = case.get("func", FUNC)
		var fd = _map_func(cobj, fn, func_cache)
		if fd.is_empty():
			out.append("  [SETUP FAIL] %s: function '%s' not found" % [name, fn])
			fail_count += 1
			continue
		if not fd.name_map.has(name):
			out.append("  [SETUP FAIL] %s: no local by that name in %s (keys: %s)"
				% [name, fn, str(fd.fobj.local_vars.keys())])
			fail_count += 1
			continue

		var tr = fd.fobj.get_local_var_type_rich(fd.name_map[name])
		var actual: String = tr.get("type", "") if tr is Dictionary else "<null>"
		var actual_origin: String = tr.get("origin", "") if tr is Dictionary else "<null>"

		if probe_all_mode or case.get("probe", false):
			out.append("  [PROBE] %-22s -> '%s'\n           origin '%s'" % [name, actual, actual_origin])
			continue

		# A type path carries at most ONE type delimiter: the "##Type" tail is terminal, and
		# Utils.type_path_get_type() reads get_slice(TYPE_DELIM, 1). Anything that nests a second one
		# (an enum wrapped as "owner::member##Error##Enum", say) gets silently truncated to the middle
		# segment, and every consumer downstream stops recognising the type. Asserted on every case
		# rather than only the enum ones, because the collision belongs to the FORMAT, not to enums.
		var shape_err := _check_type_path_shape(actual, actual_origin)
		if shape_err != "":
			fail_count += 1
			out.append("  [FAIL]  %-22s %s" % [name, shape_err])
			continue

		if actual != case.expected:
			fail_count += 1
			out.append("  [FAIL]  %-22s expected '%s' got '%s'" % [name, case.expected, actual])
			continue

		# `origin` is optional per case: it is the declaring member path the completions layer keys off
		# (dict_key.gd -> get_member_data_from_origin), and it is NOT the same walk as `type`.
		if case.has("origin"):
			if actual_origin != case.origin:
				fail_count += 1
				out.append("  [FAIL]  %-22s origin expected '%s' got '%s'" % [name, case.origin, actual_origin])
				continue
			var origin_err := _check_origin_resolves(parser, actual_origin)
			if origin_err != "":
				fail_count += 1
				out.append("  [FAIL]  %-22s origin '%s' -> %s" % [name, actual_origin, origin_err])
				continue

		pass_count += 1
		out.append("  [PASS]  %-22s -> '%s'" % [name, actual])

	out.append("--------------------------------------------------------")
	if probe_all_mode:
		out.append("  probe mode (nothing asserted)")
	else:
		out.append("  %d passed, %d failed" % [pass_count, fail_count])
	out.append("========================================================")
	return fail_count


#region Harness internals ------------------------------------------------------------------

## The type-path format invariant: `[script][.Inner][::member]##Type[$$INS]` - the `##Type` tail is
## terminal and may not itself contain `##`. Verified against every case here (46 of them carry a
## `##`) before being asserted, so this is a real invariant and not a guess.
static func _check_type_path_shape(type_str: String, origin: String) -> String:
	for pair in [["type", type_str], ["origin", origin]]:
		var value: String = pair[1]
		if value.count(Keys.TYPE_DELIM) > 1:
			return "nested '%s' in %s '%s' - type_path_get_type() reads only the first slice, so this truncates" \
				% [Keys.TYPE_DELIM, pair[0], value]
	return ""

## An origin that only *looks* right is useless to the layer that consumes it. dict_key.gd (the
## `#! keys` dict-key completion) feeds origin straight to get_member_data_from_origin() to reach the
## declaring member, so assert the same round-trip here: the member named in the origin tail must
## resolve back to that member's data. Returns "" when there is nothing to check (a bare origin like
## "Dictionary", or a script/class path with no `::member` tail).
static func _check_origin_resolves(parser: GDScriptParser, origin: String) -> String:
	var utils = GDScriptParser.Utils
	if not utils.is_absolute_path(origin):
		return ""
	var member: String = utils.type_path_get_member(origin) # drops the ##Type tail
	if member == "":
		return ""
	var member_data = parser.get_member_data_from_origin(origin)
	if member_data == null:
		return "get_member_data_from_origin returned null (unusable by dict_key.gd)"
	var found := str(member_data.get(GDScriptParser.Keys.MEMBER_NAME, ""))
	if found != member:
		return "resolved to member '%s', expected '%s'" % [found, member]
	return ""


## Mirror the editor: build the global-class registry from ProjectSettings (absent headless signal).
static func _ensure_global_class_registry() -> void:
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()


## Map a function's locals once and cache { fobj, name_map(plain name -> `name-line-col` key) }.
## Returns {} if the function isn't found.
static func _map_func(cobj, func_name: String, cache: Dictionary) -> Dictionary:
	if cache.has(func_name):
		return cache[func_name]
	var fobj = cobj.get_function(func_name)
	if fobj == null:
		return {}
	fobj.map_variables()
	var name_map := {}
	for key in fobj.local_vars.keys():
		name_map[String(key).get_slice("-", 0)] = key
	var data := {"fobj": fobj, "name_map": name_map}
	cache[func_name] = data
	return data


static func _make_parser(script_path: String, use_tree_sitter := true) -> GDScriptParser:
	_ensure_global_class_registry()
	var parser := GDScriptParser.new()
	parser.set_use_tree_sitter(use_tree_sitter) # before parse(); forces the parse path under test
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.active_parser = parser
	parser.set_current_script(load(script_path))
	parser.set_source_code(load(script_path).source_code)
	parser.parse()
	return parser

#endregion
