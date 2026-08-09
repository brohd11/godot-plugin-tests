@tool
extends RefCounted
## Enum-typing coverage: the three kinds of enum x every shape a value can acquire one from.
##
##   script-declared  GpBase.State      -> "res://gp_base.gd::State##Enum"   (absolute path)
##   @GlobalScope     Error, Key        -> "Error##Enum"                     (is_global_enum)
##   ClassDB class    Node.ProcessMode  -> "Node::ProcessMode##Enum"         (class_has_enum)
##
## These are three SEPARATE resolution paths. Only the local-var shape had ever been tested, which is
## how @GlobalScope enums came to be broken in the member / arg / return shapes while the suite stayed
## green. Everything downstream keys off one thing - the type ending in "##Enum" - because
## enum_completion._process_identifier() bails immediately without it. So that is what is asserted.
##
##     load("res://tests/brohd/gdscript_parser/global_enum_test.gd").run_tests()

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser
const Keys = GDScriptParser.Keys

const SCENARIO := "res://tests/brohd/gdscript_parser/scenarios/scenario_global_enum.gd"

const ENUM_SUFFIX := Keys.ENUM_PATH_SUFFIX
const GLOBAL_ERR := "Error" + ENUM_SUFFIX
const GLOBAL_KEY := "Key" + ENUM_SUFFIX
const CLASS_PM := "Node::ProcessMode" + ENUM_SUFFIX
const SCRIPT_STATE := "res://tests/brohd/gdscript_parser/fixtures/gp_base.gd::State" + ENUM_SUFFIX


## `kind` is where the caret sits: an operand (`op`), a call argument (`arg`), or a match branch
## (`match`, caret BEFORE the anchor). These are the three entry points enum_completion has.
static func _cases() -> Array:
	return [
		# --- @GlobalScope enum. Only local_var survived the regression; every other shape handed over a
		#     bare "Error", which reads as an ordinary type and offers no members.
		{"name": "global_local_var",         "anchor": "\tif e == ",                  "kind": "op",    "expected": GLOBAL_ERR},
		{"name": "global_member_var",        "anchor": "\tif _member_err == ",        "kind": "op",    "expected": GLOBAL_ERR},
		{"name": "global_func_arg",          "anchor": "\ttake_err(",                 "kind": "arg",   "expected": GLOBAL_ERR},
		{"name": "global_from_return",       "anchor": "\tif r == ",                  "kind": "op",    "expected": GLOBAL_ERR},
		{"name": "global_match",             "anchor": "\t\tOK: pass",                "kind": "match", "expected": GLOBAL_ERR},
		{"name": "global_const",             "anchor": "\tif CONST_ERR == ",          "kind": "op",    "expected": GLOBAL_ERR},
		{"name": "global_const_inferred",    "anchor": "\tif CONST_ERR_INFERRED == ", "kind": "op",    "expected": GLOBAL_ERR},
		# inheritance is where the last three bugs in this parser hid, so every kind gets tested across it
		{"name": "global_inherited_member",  "anchor": "\tif _base_err == ",          "kind": "op",    "expected": GLOBAL_ERR},
		{"name": "global_inherited_arg",     "anchor": "\tbase_takes_err(",           "kind": "arg",   "expected": GLOBAL_ERR},
		{"name": "global_inherited_return",  "anchor": "\tif br == ",                 "kind": "op",    "expected": GLOBAL_ERR},
		{"name": "global_inner_class_member","anchor": "\tif h.inner_err == ",        "kind": "op",    "expected": GLOBAL_ERR},

		# --- ClassDB class enum: a third resolution path (class_has_enum), only ever covered as an
		#     inferred local (inference_tests: nested_direct / nested_call_ret).
		{"name": "class_local_var",          "anchor": "\tif pm == ",                 "kind": "op",  "expected": CLASS_PM},
		{"name": "class_member_var",         "anchor": "\tif _member_pm == ",         "kind": "op",  "expected": CLASS_PM},
		{"name": "class_func_arg",           "anchor": "\ttake_pm(",                  "kind": "arg", "expected": CLASS_PM},
		{"name": "class_from_return",        "anchor": "\tif rp == ",                 "kind": "op",  "expected": CLASS_PM},
		{"name": "class_inherited_member",   "anchor": "\tif _base_pm == ",           "kind": "op",  "expected": CLASS_PM},
		# An engine PROPERTY backed by an enum. The api dump types these "int" and gives no hint - the enum
		# survives only on the property's GETTER (get_process_mode -> "enum::Node.ProcessMode"), which is
		# the same "enum::" form the resolver already converts. ~490 properties are in this shape.
		{"name": "class_instance_prop",      "anchor": "\tif n.process_mode == ",     "kind": "op",  "expected": CLASS_PM},
		# ...and off a DERIVED class, which resolves only by walking ClassDB parents (process_mode is
		# declared on Node) - the same walk the ~88 parent-declared getters depend on.
		{"name": "class_inherited_prop",     "anchor": "\tif sp.process_mode == ",    "kind": "op",  "expected": CLASS_PM},

		# --- script-declared enum: the control. Correct throughout, must stay that way.
		{"name": "script_local_var",         "anchor": "\tif s == ",                  "kind": "op",    "expected": SCRIPT_STATE},
		{"name": "script_member_var",        "anchor": "\tif _member_state == ",      "kind": "op",    "expected": SCRIPT_STATE},
		{"name": "script_func_arg",          "anchor": "\ttake_state(",               "kind": "arg",   "expected": SCRIPT_STATE},
		{"name": "script_from_return",       "anchor": "\tif rs == ",                 "kind": "op",    "expected": SCRIPT_STATE},
		{"name": "script_match",             "anchor": "\t\tGpBase.State.IDLE: pass", "kind": "match", "expected": SCRIPT_STATE},

		# --- KNOWN GAP, probed not asserted: builtin-class enums. 'Vector2.AXIS_X' -> ''.
		# Vector2 is a BUILTIN class, not a ClassDB one, and _load_extension_api() loads only
		# METHODS/CONSTANTS/MEMBERS for builtin classes - never ENUMS (the ClassDB loop right below it
		# does load them). Deliberately left alone: the ENTIRE set is 7 classes holding 2 enums (Axis on
		# Vector2/2i/3/3i/4/4i, Projection.Planes), and NO method in the builtin api returns one of them
		# (Vector2.max_axis_index() is typed plain "int"), so nothing in the engine ever produces a value
		# of these types. Fixing it would also need a second change in enum_completion, whose "::" branch
		# goes through ClassDB - which does not know Vector2.
		{"name": "class_int_const",          "anchor": "\tif axis == ",               "kind": "op",  "probe": true},
	]


## Builtin METHOD types (args and returns) are the one path that reaches the completion layer without
## passing through the type resolver - BuiltInChecker.get_func_data() hands them straight to
## FunctionCallData. So this is where the api's own "enum::Node.ProcessMode" notation used to leak out
## verbatim, and nothing downstream recognises it (everything tests for the "##Enum" suffix).
static func _builtin_method_cases() -> Array:
	return [
		{"name": "class_prop_setter_arg", "anchor": "\tn2.set_process_mode(", "kind": "arg", "expected": CLASS_PM},
		{"name": "class_method_return",   "anchor": "\tif pm2 == ",           "kind": "op",  "expected": CLASS_PM},
	]


## CONTROL: ordinary properties, i.e. the ones whose getter returns no enum. The risk in reading the
## getter is MIS-typing everything else, so a non-enum property is asserted to be exactly what it
## always was. Asserted on the exact type (these must NOT end in ##Enum, so they cannot go through
## _check).
static func _plain_cases() -> Array:
	return [
		{"name": "plain_prop_control", "anchor": "\tif n3.name == ", "kind": "op", "expected": "StringName"},
	]


## An enum's VALUES resolve to the enum's own type path. These already worked (the api dump records
## each value as `type: "enum::<Name>"`) and the fix to the enum NAME must not disturb them - the first
## patch attempted here would have turned OK into "OK##Enum".
static func _value_cases() -> Array:
	return [
		{"name": "value_ok",     "expression": "OK",     "expected": GLOBAL_ERR},
		{"name": "value_failed", "expression": "FAILED", "expected": GLOBAL_ERR},
		{"name": "value_key_a",  "expression": "KEY_A",  "expected": GLOBAL_KEY},
	]


static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


static func _run(out: Array) -> int:
	var fails := 0
	var parser = _make_parser(SCENARIO)
	var lines: PackedStringArray = (load(SCENARIO).source_code as String).split("\n")

	for case in _cases() + _builtin_method_cases():
		var caret := _find_caret(lines, case.anchor, case.kind)
		if caret.x == -1:
			out.append("  [SETUP FAIL] %s: anchor not found -> %s" % [case.name, case.anchor])
			fails += 1
			continue

		var resolved := _resolve_at(parser, caret, case.kind)
		if case.get("probe", false):
			out.append("  PROBE %-26s -> '%s'  (known gap, not asserted)" % [case.name, resolved.type])
			continue

		var failure := _check(case, resolved)
		if failure == "":
			out.append("  PASS  %-26s -> %s" % [case.name, resolved.type])
		else:
			out.append("  FAIL  %-26s %s" % [case.name, failure])
			fails += 1

	for case in _plain_cases():
		var caret := _find_caret(lines, case.anchor, case.kind)
		if caret.x == -1:
			out.append("  [SETUP FAIL] %s: anchor not found -> %s" % [case.name, case.anchor])
			fails += 1
			continue
		var resolved := _resolve_at(parser, caret, case.kind)
		if resolved.type == case.expected:
			out.append("  PASS  %-26s -> %s (unchanged by the getter lookup)" % [case.name, resolved.type])
		else:
			out.append("  FAIL  %-26s expected '%s' got '%s' - the getter lookup mistyped an ordinary property"
				% [case.name, case.expected, resolved.type])
			fails += 1

	for case in _value_cases():
		var type_str: String = parser.resolve_expression_to_type(case.expression, 30)
		if type_str == case.expected:
			out.append("  PASS  %-26s -> %s" % [case.name, type_str])
		else:
			out.append("  FAIL  %-26s '%s' resolved to '%s', expected '%s'"
				% [case.name, case.expression, type_str, case.expected])
			fails += 1

	out.append("\nGLOBAL ENUM: %s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	return fails


## Three assertions, because they fail for different reasons and a green is worthless if any is
## skipped:
##   1. no NESTED type delimiter, checked on `origin` as well as `type` - and ORIGIN is where it shows.
##      A member typed to a global enum resolved to "script.gd::_member_err##Error##Enum"; by the time
##      `type` is read, type_path_get_type() has already truncated that to "Error", so the type alone
##      only shows the symptom. The origin still carries the malformed path, i.e. the actual bug.
##   2. the "##Enum" marker - the single thing enum_completion._process_identifier() switches on.
##   3. the exact type path.
static func _check(case: Dictionary, resolved: Dictionary) -> String:
	for field in ["type", "origin"]:
		var value: String = resolved[field]
		if value.count(Keys.TYPE_DELIM) > 1:
			return "nested '%s' in %s '%s' - type_path_get_type() truncates this to the middle segment" \
				% [Keys.TYPE_DELIM, field, value]
		# "enum::Node.ProcessMode" is the engine api's notation and BuiltInChecker's internal dialect.
		# It is NOT a type path, and nothing downstream recognises it - so it must never reach a
		# consumer. Utils.type_path_from_api_enum() converts it at every boundary; this is that rule.
		if value.begins_with(Keys.API_ENUM_PREFIX):
			return "raw api enum notation in %s '%s' - it should have been converted to a type path" \
				% [field, value]

	var type_str: String = resolved.type
	if not type_str.ends_with(ENUM_SUFFIX):
		return "'%s' does not end with %s - enum completion bails here" % [type_str, ENUM_SUFFIX]
	if type_str != case.expected:
		return "expected '%s' got '%s'" % [case.expected, type_str]
	return ""


## Returns {type, origin}. A call argument has no origin of its own here (the FunctionCallData origin
## names the FUNCTION, not the argument), so it reports an empty one rather than a misleading one.
static func _resolve_at(parser, caret: Vector2i, kind: String) -> Dictionary:
	parser.code_edit.set_caret_line(caret.y)
	parser.code_edit.set_caret_column(caret.x)
	parser.reset_caret_context()
	var cc = parser.get_caret_context()

	var symbol_data
	match kind:
		"arg":
			return {"type": cc.get_function_call_data().get_current_arg_type(), "origin": ""}
		"match":
			var match_data = cc.get_match_block_data()
			if not match_data or not match_data.is_valid:
				return {"type": "<match block data invalid>", "origin": ""}
			symbol_data = match_data.symbol_data
		_:
			symbol_data = cc.get_operation_data().left_symbol_data

	return {"type": symbol_data.type, "origin": symbol_data.origin}


## A match branch is completed with the caret at the START of the pattern; every other shape completes
## after the anchor.
static func _find_caret(lines: PackedStringArray, anchor: String, kind: String) -> Vector2i:
	for i in lines.size():
		var col := lines[i].find(anchor)
		if col != -1:
			return Vector2i(col if kind == "match" else col + anchor.length(), i)
	return Vector2i(-1, -1)


static func _make_parser(script_path: String):
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()
	var parser = GDScriptParser.new()
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.active_parser = parser
	parser.set_current_script(load(script_path))
	parser.set_source_code(load(script_path).source_code)
	parser.parse()
	return parser
