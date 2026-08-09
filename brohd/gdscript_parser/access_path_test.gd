@tool
extends RefCounted
## Access-path resolution stress tests for the gdscript parser.
##
## Each case names a scenario script, an anchor to locate a caret, and the expected AccessOptions.
## The runner spins up a GDScriptParser per scenario script, simulates the caret, drives the real
## caret-context -> access.gd path, and asserts the resolved standard / script_alias / global.
##
## Run it (returns {result: fail count, output: report lines}):
##     load("res://tests/brohd/gdscript_parser/access_path_test.gd").run_tests()
##
## IMPORTANT: a *running* editor caches the parser scripts (access.gd et al.) via preloaded
## consts, so edits to them are NOT reliably hot-reloaded - restart the editor first, or use the
## clean-compile headless runner:
##     godot --headless --path . --script res://tests/brohd/gdscript_parser/run_headless.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser

const DIR := "res://tests/brohd/gdscript_parser/"
const BASIC := DIR + "scenarios/scenario_basic.gd"
const INHERIT := DIR + "scenarios/scenario_inheritance.gd"
const ALIASES := DIR + "scenarios/scenario_aliases.gd"
const COLLISION := DIR + "scenarios/scenario_collision.gd"
const INSCRIPT := DIR + "scenarios/scenario_inscript_arg.gd"
const SERVICE := DIR + "fixtures/gp_service.gd"
const KIT_DERIVED := DIR + "fixtures/gp_kit_derived.gd"
const INHERITING_CALLER := DIR + "scenarios/scenario_inheriting_caller.gd"
const ANON_CALLER := DIR + "scenarios/scenario_anon_caller.gd"
const CYCLE_B := DIR + "fixtures/gp_cycle_b.gd"


## Each case: the scenario `script`, the `anchor` text used to locate the caret, whether the caret
## sits `before`/`after` it, the completion `kind` (op|match|func), and the `expected` AccessOptions
## fields (only listed fields are asserted). `probe: true` prints the resolved values without
## asserting (used while authoring / locking in new expected strings).
static func _cases() -> Array:
	return [
		# --- scenario_basic ---
		{"name": "repro_inner_enum_via_return", "script": BASIC,
			"anchor": "\tif alert == ", "caret": "after", "kind": "op",
			"expected": {"standard": "GpAlert.AlertType"}},
		{"name": "nested_two_level_not_collapsed", "script": BASIC,
			"anchor": "\tif m == ", "caret": "after", "kind": "op",
			"expected": {"standard": "Outer.Mid.MidNum"}},
		{"name": "same_name_nested_probe", "script": BASIC,
			"anchor": "\tif n == ", "caret": "after", "kind": "op",
			"expected": {}, "probe": true},
		{"name": "self_scope_top_enum", "script": BASIC,
			"anchor": "\tif t == ", "caret": "after", "kind": "op",
			"expected": {"standard": "TopEnum"}},
		{"name": "match_branch_arg_enum", "script": BASIC,
			"anchor": "\t\tGpAlert.AlertType.NONE", "caret": "before", "kind": "match",
			"expected": {"standard": "GpAlert.AlertType"}},
		{"name": "function_arg_enum", "script": BASIC,
			"anchor": "\t_take_alert(", "caret": "after", "kind": "func",
			"expected": {"standard": "GpAlert.AlertType"}},

		# --- scenario_inheritance (inherited class/enum + cross-script aliases) ---
		# Inherited enum accessed unqualified; the global field carries the fully-qualified path.
		{"name": "inherited_enum", "script": INHERIT,
			"anchor": "\tif st == ", "caret": "after", "kind": "op",
			"expected": {"standard": "State", "script_alias": "State", "global": "GpBase.State"}},
		# As-typed inherited const alias is preserved (not rewritten to the underlying State).
		{"name": "inherited_const_alias", "script": INHERIT,
			"anchor": "\tif sa == ", "caret": "after", "kind": "op",
			"expected": {"standard": "StateAlias", "global": "GpBase.State"}},
		{"name": "inherited_inner_class_enum", "script": INHERIT,
			"anchor": "\tif mo == ", "caret": "after", "kind": "op",
			"expected": {"standard": "Handle.Mode", "global": "GpBase.Handle.Mode"}},
		{"name": "cross_global_class_enum", "script": INHERIT,
			"anchor": "\tif kind == ", "caret": "after", "kind": "op",
			"expected": {"standard": "GpWidgets.Kind", "global": "GpWidgets.Kind"}},
		{"name": "cross_preload_alias_enum", "script": INHERIT,
			"anchor": "\tif kind2 == ", "caret": "after", "kind": "op",
			"expected": {"standard": "Widgets.Kind"}},
		{"name": "match_inherited_enum", "script": INHERIT,
			"anchor": "\t\tState.IDLE", "caret": "before", "kind": "match",
			"expected": {"standard": "State"}},
		# The arg is declared `take(s: GS)`; the finder factors that in -> the arg's own alias GS,
		# prefixed by how the caller reached the class.
		{"name": "inner_class_func_arg_via_alias", "script": INHERIT,
			"anchor": "GpWidgets.Group.take(", "caret": "after", "kind": "func",
			"expected": {"standard": "GpWidgets.Group.GS"}},

		# --- gp_service in-script alias sites (caller has T / TS / Scale in scope) ---
		{"name": "local_full_path_arg", "script": SERVICE,
			"anchor": "\ttf_full(", "caret": "after", "kind": "func",
			"expected": {"standard": "Ticker.Scale"}},
		{"name": "local_ts_alias_arg", "script": SERVICE,
			"anchor": "\ttf_ts(", "caret": "after", "kind": "func",
			"expected": {"standard": "TS"}},
		{"name": "local_scale_alias_return", "script": SERVICE,
			"anchor": "\tif sc == ", "caret": "after", "kind": "op",
			"expected": {"standard": "Scale"}},

		# --- scenario_aliases (cross-script user-typed alias matching) ---
		# Func-arg completion from another script: the arg's declared type spelling (Ticker.Scale / TS
		# in gp_service), prefixed by the caller's preload alias `Service`, with the fully-qualified
		# path via `global`.
		{"name": "cross_call_full_path", "script": ALIASES,
			"anchor": "\ts.tf_full(", "caret": "after", "kind": "func",
			"expected": {"standard": "Service.Ticker.Scale", "global": "GpService.Ticker.Scale"}},
		{"name": "cross_call_caller_alias", "script": ALIASES,
			"anchor": "\ts.tf_ts(", "caret": "after", "kind": "func",
			"expected": {"standard": "Service.TS"}},
		{"name": "cross_return_enum", "script": ALIASES,
			"anchor": "\tif v == ", "caret": "after", "kind": "op",
			"expected": {"standard": "GpService.Scale"}},
		{"name": "cross_match_enum", "script": ALIASES,
			"anchor": "\t\tGpService.Ticker.Scale.MSEC", "caret": "before", "kind": "match",
			"expected": {"standard": "GpService.Ticker.Scale"}},
		# The new_ins shape (see `trim_ins`): a BARE inner class instance of a script with no
		# class_name. `global` is legitimately empty, and the type lives in inner_classes rather than
		# constants - so it is only reachable by chaining the caller's preload const onto the inner
		# class name. Regression guard for both inner-class blind spots (has_preload skipping its own
		# inner_classes, and the reverse chain search never stepping down to script scope).
		{"name": "cross_bare_inner_class_instance", "script": ALIASES,
			"anchor": "\tp = ", "caret": "after", "kind": "op", "trim_ins": true,
			"expected": {"standard": "Anon.Payload", "script_alias": "Anon.Payload", "global": ""}},
		{"name": "cross_bare_inner_class_instance_deep", "script": ALIASES,
			"anchor": "\td = ", "caret": "after", "kind": "op", "trim_ins": true,
			"expected": {"standard": "Anon.Outer.Deep", "script_alias": "Anon.Outer.Deep", "global": ""}},

		# --- scenario_anon_caller (the exact new_ins.gd shape) ---
		# Same bare inner class, but now NOTHING in the caller's own scope names it: the object comes
		# from an inherited method and the preload const lives in the base script. The caller's access
		# object is just the local var, so the path can only be built by searching - which is where the
		# inner-class blind spots bite.
		{"name": "inherited_alias_bare_inner_class", "script": ANON_CALLER,
			"anchor": "\tp = ", "caret": "after", "kind": "op", "trim_ins": true,
			"expected": {"standard": "Anon.Payload", "script_alias": "Anon.Payload", "global": ""}},
		{"name": "inherited_alias_bare_inner_class_deep", "script": ANON_CALLER,
			"anchor": "\td = ", "caret": "after", "kind": "op", "trim_ins": true,
			"expected": {"standard": "Anon.Outer.Deep", "script_alias": "Anon.Outer.Deep", "global": ""}},

		# --- scenario_collision (dual-access: prefix the secondary arg decl with the caller's reach) ---
		# The caller has its OWN Inner.Mode; the finder must reach the derived class's members instead.
		# Secondary alias (MU) factored in, prefixed by the caller's reach to the object's class.
		{"name": "cross_arg_alias_factored", "script": COLLISION,
			"anchor": "\tn.tf_simple(", "caret": "after", "kind": "func",
			"expected": {"standard": "GpKitDerived.MT.Unit", "global": "GpKitBase.Meter.Unit"}},
		# Same-named Inner collision: resolves to the derived class's Inner.Mode, never the caller's.
		{"name": "cross_arg_inner_collision", "script": COLLISION,
			"anchor": "\tic.use_mode(", "caret": "after", "kind": "func",
			"expected": {"standard": "GpKitDerived.Inner.Mode"}},
		# Secondary member lives in an outer/sibling scope of the object's class -> front prefix.
		{"name": "cross_arg_outer_scope", "script": COLLISION,
			"anchor": "\tic.use_outer(", "caret": "after", "kind": "func",
			"expected": {"standard": "GpKitDerived.Bundle.Layer.Tag"}},
		# Bare inner class as the arg type (print_debug.gd `S` shape): must be the qualified path,
		# never the caller's own bare `Sig`.
		{"name": "cross_arg_bare_inner_class", "script": COLLISION,
			"anchor": "\tn.emit(", "caret": "after", "kind": "func",
			"expected": {"standard": "GpKitDerived.Sig", "global": "GpKitBase.Sig"}},
		# Inherited call from INSIDE the derived script. The arg is spelled "MT.Unit" in GpKitBase's
		# scope, yet the caller inherits GpKitBase, so it is usable verbatim - the secondary must be
		# offered as-typed, not prefixed. This is what the reachability predicate in access.gd protects:
		# the declaring script (base) is NOT the caller's script, so a plain script-equality check would
		# route this through the cross-script ordering and prefix it.
		{"name": "inherited_call_within_derived", "script": KIT_DERIVED,
			"anchor": "\ttf_simple(", "caret": "after", "kind": "func",
			"expected": {"standard": "MT.Unit"}},
		# The caller extends GpKitBase and calls the inherited method on a DIFFERENT derived instance.
		# Both "MT.Unit" (the caller inherits MT) and "GpKitDerived.MT.Unit" resolve, so only candidate
		# order decides - and order comes from the reachability predicate. Without it, this is offered
		# needlessly prefixed.
		{"name": "inherited_arg_from_inheriting_caller", "script": INHERITING_CALLER,
			"anchor": "\tn.tf_simple(", "caret": "after", "kind": "func",
			"expected": {"standard": "MT.Unit"}},

		# -- In-script dual-arg: object is an inner class of THIS script; the arg type is written in
		#    this script's own scope, so the finder must offer it as-typed, never prefixed with Holder.
		{"name": "inscript_arg_alias", "script": INSCRIPT,
			"anchor": "\th.take(", "caret": "after", "kind": "func",
			"expected": {"standard": "StateRef"}},
		{"name": "inscript_arg_dotted_global", "script": INSCRIPT,
			"anchor": "\th.take2(", "caret": "after", "kind": "func",
			"expected": {"standard": "GpBase.State"}},

		# --- kind "tag": the arg_location.gd shape. The `#! arg_location arg:Location` tag names a class
		#     holding the constants to offer, and it is written above the function's DECLARATION - so the
		#     `location` string is spelled in the DECLARING script's scope, while the path handed back
		#     must be typable from the CALLER's. Every tag case also round-trips (see _check_tag_usable).
		# The caller reaches the object through its own preload const `Service`, which exists ONLY in the
		# caller's script - so a candidate can only be verified in the caller's parser. Verifying in the
		# target's parser instead rejects "Service.Ticker" and accepts the bare "Ticker", which the caller
		# cannot type.
		{"name": "tag_location_via_preload_alias", "script": ALIASES,
			"anchor": "\ts.tf_full(", "caret": "after", "kind": "tag", "location": "Ticker",
			"expected": {"standard": "Service.Ticker", "global": "GpService.Ticker"}},
		# Inherited call: tf_simple is declared in gp_kit_base, so "Bundle.Layer" is spelled in the BASE's
		# scope, while the caller reached the object as GpKitDerived.
		{"name": "tag_location_inherited", "script": COLLISION,
			"anchor": "\tn.tf_simple(", "caret": "after", "kind": "tag", "location": "Bundle.Layer",
			"expected": {"standard": "GpKitDerived.Bundle.Layer"}},
		# --- gp_cycle pair (mutual preload: b extends a's preload const, a preloads b back) ---
		{"name": "cycle_cross_preload_enum", "script": CYCLE_B,
			"anchor": "\tif phase == ", "caret": "after", "kind": "op",
			"expected": {"standard": "ACycle.Phase", "script_alias": "Phase"}},
	]


## Runs the suite; returns {result: fail count (0 == all good), output: report lines}.
static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


## Diagnostic: is a freshly-built parser running the hardened access.gd?
static func has_new_access() -> bool:
	var parser := _make_parser(BASIC)
	return parser.get_access().has_method("_find_path_to_type_simple_hardened")


## Diagnostic: dump the inputs feeding find_path_to_type for a given op-case anchor.
static func debug_case(script: String = BASIC, anchor: String = "\tif alert == ") -> String:
	var out: Array = []
	out.append("script=%s anchor=%s" % [script, anchor.strip_edges()])
	var parser := _make_parser(script)
	var lines := (load(script).source_code as String).split("\n")
	var caret := _find_caret(lines, {"anchor": anchor, "caret": "after"})
	if caret.x == -1:
		return "anchor not found"
	parser.code_edit.set_caret_line(caret.y)
	parser.code_edit.set_caret_column(caret.x)
	parser.reset_caret_context()
	var cc = parser.get_caret_context()
	var op = cc.get_operation_data()
	var sd = op.left_symbol_data
	out.append("to_find(type)= " + str(sd.type))
	out.append("declaring_script_path= " + str(sd.declaring_script_path))
	var cur = sd.get_current_script_access_object()
	var sec = sd.get_declaring_script_access_object()
	out.append("current_access: sym='%s' type='%s'" % [cur.declaration_symbol if cur else "<null>", cur.declaration_type if cur else "<null>"])
	out.append("secondary_access: sym='%s' type='%s'" % [sec.declaration_symbol if sec else "<null>", sec.declaration_type if sec else "<null>"])
	var opts = op.get_type_access_path()
	if opts is Object:
		out.append("RESULT standard='%s' alias='%s' global='%s'" % [opts.standard, opts.script_alias, opts.global])
	else:
		out.append("RESULT (non-absolute, type resolver returned a plain string): '%s'" % str(opts))
	return "\n".join(out)


static func _run(out: Array) -> int:
	var ctx_cache := {}  # script_path -> {parser, lines}
	var pass_count := 0
	var fail_count := 0
	out.append("\n==================== ACCESS PATH TESTS ====================")

	for case in _cases():
		var ctx = _get_ctx(ctx_cache, case.script)
		var caret := _find_caret(ctx.lines, case)
		if caret.x == -1:
			out.append("  [SETUP FAIL] %s: anchor not found -> %s" % [case.name, case.anchor])
			fail_count += 1
			continue

		var opts = _resolve_case(ctx.parser, caret.y, caret.x, case)
		var actual := {
			"standard": opts.standard if opts else "<null>",
			"script_alias": opts.script_alias if opts else "<null>",
			"global": opts.global if opts else "<null>",
		}

		if case.get("probe", false):
			out.append("  [PROBE] %s -> standard=%s | alias=%s | global=%s"
				% [case.name, actual.standard, actual.script_alias, actual.global])
			continue

		var failures := _check_expected(case.get("expected", {}), actual)
		if case.kind == "tag" and opts != null:
			failures.append_array(_check_tag_usable(ctx.parser, caret, case, actual.standard))
		if failures.is_empty():
			pass_count += 1
			out.append("  [PASS]  %s -> %s" % [case.name, actual.standard])
		else:
			fail_count += 1
			out.append("  [FAIL]  %s" % case.name)
			for f in failures:
				out.append("            %s" % f)

	var const_result := _run_const_search(ctx_cache, out)
	pass_count += const_result[0]
	fail_count += const_result[1]

	out.append("----------------------------------------------------------")
	out.append("  %d passed, %d failed (probes not counted)" % [pass_count, fail_count])
	out.append("==========================================================")
	return fail_count


## Direct checks on the const-by-value search, which is the fallback behind `standard` when nothing
## in the caller's scope spells the type. The caret cases above can't pin it: their as-typed symbol
## usually resolves on its own, so the search never runs. Asserted here instead - an inner class must
## be reachable exactly like a const alias to one, which is what `has_preload` used to miss.
static func _run_const_search(ctx_cache: Dictionary, out: Array) -> Array:
	var cases := [
		{"name": "const_search_bare_inner_class", "script": ALIASES,
			"to_find": DIR + "fixtures/gp_anon.gd.Payload", "expected": "Anon.Payload"},
		{"name": "const_search_bare_inner_class_deep", "script": ALIASES,
			"to_find": DIR + "fixtures/gp_anon.gd.Outer.Deep", "expected": "Anon.Outer.Deep"},
	]
	var passed := 0
	var failed := 0
	for case in cases:
		var parser = _get_ctx(ctx_cache, case.script).parser
		var actual = parser.get_access().find_constant_by_value(case.to_find, parser.get_class_object(""))
		if actual == case.expected:
			passed += 1
			out.append("  [PASS]  %s -> %s" % [case.name, actual])
		else:
			failed += 1
			out.append("  [FAIL]  %s" % case.name)
			out.append("            expected '%s' got '%s'" % [case.expected, actual])
	return [passed, failed]


#region Harness internals ------------------------------------------------------------------

static func _get_ctx(cache: Dictionary, script_path: String) -> Dictionary:
	if not cache.has(script_path):
		cache[script_path] = {
			"parser": _make_parser(script_path),
			"lines": (load(script_path).source_code as String).split("\n"),
		}
	return cache[script_path]


## The global-class registry is normally built off an EditorInterface filesystem signal, which is
## absent in a headless run - so populate it directly from ProjectSettings (mirrors the editor) so
## `class_name` fixtures resolve here too.
static func _ensure_global_class_registry() -> void:
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()


static func _make_parser(script_path: String) -> GDScriptParser:
	_ensure_global_class_registry()
	var parser := GDScriptParser.new()
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.active_parser = parser
	parser.set_current_script(load(script_path))
	parser.set_source_code(load(script_path).source_code)
	parser.parse()
	return parser


## Returns Vector2i(column, line) for the caret, or x == -1 if the anchor is not found.
static func _find_caret(lines: PackedStringArray, case: Dictionary) -> Vector2i:
	var anchor: String = case.anchor
	for i in lines.size():
		var col := lines[i].find(anchor)
		if col == -1:
			continue
		if case.caret == "after":
			col += anchor.length()
		return Vector2i(col, i)
	return Vector2i(-1, -1)


static func _resolve_case(parser: GDScriptParser, line: int, column: int, case: Dictionary):
	parser.code_edit.set_caret_line(line)
	parser.code_edit.set_caret_column(column)
	parser.reset_caret_context()
	var cc = parser.get_caret_context()

	var result
	match case.kind:
		"op": result = _get_path(cc.get_operation_data(), case.get("trim_ins", false))
		"match": result = _get_path(cc.get_match_block_data())
		"func": result = _get_path(cc.get_function_call_data())
		"tag":
			var inputs := _tag_inputs(parser, case.get("location", ""))
			if inputs.is_empty():
				return null
			result = inputs.fcd.get_type_access_path(inputs.to_find, inputs.secondary)
		_:
			printerr("Unknown case kind: ", case.kind)
			return null

	# get_type_access_path returns an AccessOptions for script paths, or a String otherwise.
	if result is Object:
		return result
	return null


## `trim_ins` mirrors new_ins.gd, which strips the instance marker off the resolved type before
## asking for its access path - unlike the enum sites, which hand the type over untouched.
static func _get_path(comp_object, trim_ins := false):
	if comp_object == null:
		return null
	if trim_ins:
		return comp_object.get_type_access_path(_strip_ins(comp_object.left_symbol_data.type))
	return comp_object.get_type_access_path()


## Mirrors arg_location.gd: the tag's `location` names a class, spelled in the scope of the script that
## DECLARES the called function (an ancestor's, for an inherited call). Resolve it - and its access
## object - there; the call site turns that into a path the caller can type. Assumes the caret is set.
static func _tag_inputs(parser: GDScriptParser, location: String) -> Dictionary:
	var fcd = parser.get_caret_context().get_function_call_data()
	var function_script = fcd.get_function_script()
	if not GDScriptParser.Utils.is_absolute_path(function_script):
		return {}
	var script_data := GDScriptParser.Utils.type_path_get_script_data(function_script)
	return {
		"fcd": fcd,
		"to_find": parser.resolve_expression_in_script(location, script_data[0], script_data[1]),
		"secondary": parser.resolve_to_access_object_in_script(location, script_data[0], script_data[1]),
	}


## The offered path must be typable BY THE CALLER: resolve it back in the caller's own scope, at the
## caret's line, and demand it lands on the type the tag pointed at. This is independent of how the
## finder built the string, so it stays honest even if the expected value above is ever wrong.
static func _check_tag_usable(parser: GDScriptParser, caret: Vector2i, case: Dictionary, standard: String) -> Array:
	var inputs := _tag_inputs(parser, case.get("location", ""))
	if inputs.is_empty():
		return ["round-trip: no declaring script for the called function"]
	var resolved: String = parser.resolve_expression_to_type(standard, caret.y)
	if _strip_ins(resolved) != _strip_ins(inputs.to_find):
		return ["round-trip: '%s' resolves to '%s' from the caller, expected '%s'"
			% [standard, resolved, inputs.to_find]]
	return []


static func _strip_ins(type_path: String) -> String:
	return type_path.trim_suffix(GDScriptParser.Keys.INS_DELIM)


static func _check_expected(expected: Dictionary, actual: Dictionary) -> Array:
	var failures := []
	for field in expected.keys():
		if actual.get(field) != expected[field]:
			failures.append("%s: expected '%s' got '%s'" % [field, expected[field], actual.get(field)])
	return failures

#endregion
