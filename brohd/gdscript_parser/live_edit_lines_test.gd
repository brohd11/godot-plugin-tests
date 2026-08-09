@tool
extends RefCounted
## sync_line_ranges() must keep class/function line ranges tracking the buffer between full parses.
##
## The bug it guards: tree-sitter's grammar decides where a function ends, so a function whose last
## body line is a comment ends at the statement ABOVE it. Typing a real statement underneath extends
## the function, but func_lines is only rebuilt by a full parse() - which the editor runs on the
## debounced VALIDATE_SCRIPT, not per keystroke. In that window get_function_at_line() returns
## CLASS_BODY for the line just typed and its local is unresolvable, which is exactly when completion
## asks. sync_line_ranges() closes the window WITHOUT touching members, types or resolve caches.
##
##     load("res://tests/brohd/gdscript_parser/live_edit_lines_test.gd").run_tests()
##
## IMPORTANT: a *running* editor caches the parser scripts via preloaded consts, so edits to them are
## NOT reliably hot-reloaded - use the clean-compile headless runner:
##     Godot --headless --path . --script res://tests/brohd/gdscript_parser/run_all_headless.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser

const DIR := "res://tests/brohd/gdscript_parser/"
const SCENARIO := DIR + "scenarios/scenario_live_edit.gd"

## The statement typed under the trailing comment of _click(), and a whole function typed from
## scratch (which sync must leave alone - it has no ParserFunc until the next parse).
const TYPED_STATEMENT := "\tvar sel := {}\n"
const TYPED_FUNCTION := "\nfunc brand_new() -> void:\n\tpass\n"


static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


static func _run(out: Array) -> int:
	out.append("\n=============== LIVE EDIT LINES ===============")
	# sync_line_ranges() reads the tree-sitter tree; the plain-text path has no cheap equivalent.
	if not ClassDB.class_exists("GDScriptTreeSitter"):
		out.append("  (GDScriptTreeSitter not registered - suite skipped)")
		out.append("\nLIVE EDIT LINES: ALL PASS (skipped)")
		return 0

	var fails := 0
	fails += _test_repro_and_fix(out)
	fails += _test_parity_with_full_parse(out)
	fails += _test_no_op_and_isolation(out)
	fails += _test_unknown_declaration(out)
	fails += _test_local_var_remap(out)
	fails += _test_successive_edits(out)

	out.append("\nLIVE EDIT LINES: %s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	return fails


## The repro and the fix, on one parser and with NO full parse in between.
static func _test_repro_and_fix(out: Array) -> int:
	out.append("\n  -- repro / fix")
	var fails := 0
	var parser := _make_parser()
	var edited: String = parser.code_edit.text + TYPED_STATEMENT
	var new_line := _find_line(edited, "var sel := {}")
	if new_line == -1:
		out.append("  [SETUP FAIL] typed statement not found in edited buffer")
		return 1

	parser.code_edit.text = edited

	# stale ranges: the line just typed is outside func_lines, so it reads as class body
	fails += _check(out, "stale_before_sync",
		parser.get_function_at_line(new_line) == GDScriptParser.Keys.CLASS_BODY,
		"got '%s'" % parser.get_function_at_line(new_line))

	fails += _check(out, "sync_reports_change", parser.sync_line_ranges(), "returned false")

	var got_func: String = parser.get_function_at_line(new_line)
	fails += _check(out, "func_at_line_after_sync", got_func == "_click", "got '%s'" % got_func)

	var func_obj = _get_func(parser, "", "_click")
	fails += _check(out, "func_lines_covers_new_line",
		func_obj != null and func_obj.func_lines.has(new_line),
		"func_lines %s" % [func_obj.func_lines if func_obj != null else "<no func>"])

	# the end-to-end symptom: the local declared on the new line types, with NO full parse. Locals are
	# keyed by the mangled `name-line-col` and read through the func object (see inference_test).
	func_obj.map_variables()
	var key := _find_key_prefixed(func_obj.local_vars, "sel-")
	var resolved: String = str(func_obj.get_local_var_type_rich(key).get("type", ""))
	fails += _check(out, "type_local_after_sync", resolved == "Dictionary",
		"key '%s' -> '%s'" % [key, resolved])
	return fails


## A sync must produce the ranges a full parse would - guards the root `start = 0` normalisation and
## the range(start, end + 1) shape against drift from parse_text_ts / _create_function_ts.
static func _test_parity_with_full_parse(out: Array) -> int:
	out.append("\n  -- parity with full parse")
	var fails := 0
	var parser := _make_parser()
	parser.code_edit.text = parser.code_edit.text + TYPED_STATEMENT
	parser.sync_line_ranges()
	var synced := _snapshot(parser)

	parser.parse(true) # force: see _make_parser on why an edited buffer never goes cache_dirty here
	var parsed := _snapshot(parser)

	fails += _check(out, "ranges_match_full_parse", synced == parsed,
		"\n      synced: %s\n      parsed: %s" % [synced, parsed])
	return fails


## A sync is a no-op at an unchanged version, and never touches members or the resolve cache.
static func _test_no_op_and_isolation(out: Array) -> int:
	out.append("\n  -- no-op / isolation")
	var fails := 0
	var parser := _make_parser()
	# seed the root class's resolve cache - get_member_type_rich is what writes into _resolve_cache
	parser.get_class_object("").get_member_type_rich("label")

	parser.code_edit.text = parser.code_edit.text + TYPED_STATEMENT
	var members_before := parser.get_members_hash()
	var cache_before: Array = parser.get_class_object("")._resolve_cache.keys()
	fails += _check(out, "resolve_cache_seeded", not cache_before.is_empty(),
		"nothing cached - the isolation check below would be vacuous")

	fails += _check(out, "first_sync_changes", parser.sync_line_ranges(), "returned false")
	fails += _check(out, "second_sync_no_op", not parser.sync_line_ranges(),
		"returned true with no edit")
	fails += _check(out, "members_untouched", parser.get_members_hash() == members_before,
		"members hash changed")
	fails += _check(out, "resolve_cache_untouched",
		parser.get_class_object("")._resolve_cache.keys() == cache_before,
		"resolve cache keys changed")
	return fails


## A function typed from scratch has no ParserFunc yet (that needs member data). Sync must skip it
## without crashing; the next full parse picks it up.
static func _test_unknown_declaration(out: Array) -> int:
	out.append("\n  -- unknown declaration mid-typing")
	var fails := 0
	var parser := _make_parser()
	parser.code_edit.text = parser.code_edit.text + TYPED_FUNCTION

	parser.sync_line_ranges()
	fails += _check(out, "unknown_func_skipped_by_sync",
		_get_func(parser, "", "brand_new") == null, "sync created a ParserFunc")

	parser.parse(true)
	fails += _check(out, "unknown_func_added_by_parse",
		_get_func(parser, "", "brand_new") != null, "parse did not pick it up")
	return fails


## Local-var keys embed the absolute line, so a moved function must drop them and re-map. The
## re-map goes through map_variables() (a buffer scan) rather than the tree-sitter `locals` payload,
## so the two key formats have to agree - that is what this checks.
static func _test_local_var_remap(out: Array) -> int:
	out.append("\n  -- local var re-map")
	var fails := 0
	var parser := _make_parser()
	var func_obj = _get_func(parser, "", "_click")
	if func_obj == null:
		out.append("  [SETUP FAIL] no ParserFunc for '_click'")
		return 1

	var ts_key := _find_key_prefixed(func_obj.local_vars, "count-")
	if ts_key == "":
		out.append("  [SETUP FAIL] tree-sitter payload has no 'count' local: %s"
			% [func_obj.local_vars.keys()])
		return 1

	parser.code_edit.text = parser.code_edit.text + TYPED_STATEMENT
	parser.sync_line_ranges()
	fails += _check(out, "locals_dropped_on_move", func_obj.local_vars.is_empty(),
		"still holds %s" % [func_obj.local_vars.keys()])

	func_obj.map_variables()
	# `count` did not move, so the re-mapped key must be byte-identical to the tree-sitter one
	fails += _check(out, "remap_key_matches_tree_sitter", func_obj.local_vars.has(ts_key),
		"expected '%s', got %s" % [ts_key, func_obj.local_vars.keys()])
	fails += _check(out, "remap_sees_typed_local",
		_find_key_prefixed(func_obj.local_vars, "sel-") != "",
		"got %s" % [func_obj.local_vars.keys()])
	return fails


## Two edits in a row, each followed by a sync. Guards the tree-sitter manager's per-revision
## sparse_parse() cache: one that never invalidates serves the FIRST edit's ranges forever, which
## every single-edit case above would still pass.
static func _test_successive_edits(out: Array) -> int:
	out.append("\n  -- successive edits (sparse cache invalidation)")
	var fails := 0
	var parser := _make_parser()
	var func_obj = _get_func(parser, "", "_click")
	if func_obj == null:
		out.append("  [SETUP FAIL] no ParserFunc for '_click'")
		return 1

	for edit_num in [1, 2]:
		parser.code_edit.text = parser.code_edit.text + TYPED_STATEMENT
		var line := _find_line(parser.code_edit.text, "var sel := {}")
		# each appended statement is the new last line of _click, so the range must reach it
		var expected_end := parser.code_edit.text.split("\n").size() - 2
		fails += _check(out, "edit_%d_sync_reports_change" % edit_num, parser.sync_line_ranges(),
			"returned false - cache did not invalidate")
		var got_end := -1
		if not func_obj.func_lines.is_empty():
			got_end = func_obj.func_lines[func_obj.func_lines.size() - 1]
		fails += _check(out, "edit_%d_range_reaches_new_line" % edit_num, got_end == expected_end,
			"func_lines end %d, expected %d (first match at line %d)" % [got_end, expected_end, line])
	return fails


#region Harness internals ------------------------------------------------------------------

static func _check(out: Array, name: String, ok: bool, detail: String = "") -> int:
	if ok:
		out.append("  PASS  %s" % name)
		return 0
	out.append("  FAIL  %s  %s" % [name, detail])
	return 1


## {access_path: {"lines": [first, last], "funcs": {name: [declaration_line, end_line]}}}
static func _snapshot(parser: GDScriptParser) -> Dictionary:
	var data := {}
	for access_path in parser.get_classes():
		var class_obj = parser.get_class_object(access_path)
		var lines: PackedInt32Array = class_obj.line_indexes
		var funcs := {}
		for func_name in class_obj.functions.keys():
			var func_obj = class_obj.functions[func_name]
			var fl: PackedInt32Array = func_obj.func_lines
			funcs[func_name] = [fl[0] if not fl.is_empty() else -1,
				fl[fl.size() - 1] if not fl.is_empty() else -1]
		data[access_path] = {
			"lines": [lines[0] if not lines.is_empty() else -1,
				lines[lines.size() - 1] if not lines.is_empty() else -1],
			"funcs": funcs,
		}
	return data


static func _get_func(parser: GDScriptParser, access_path: String, func_name: String) -> Variant:
	var class_obj = parser.get_class_object(access_path)
	if class_obj == null:
		return null
	return class_obj.functions.get(func_name)


static func _find_key_prefixed(dict: Dictionary, prefix: String) -> String:
	for key in dict.keys():
		if str(key).begins_with(prefix):
			return key
	return ""


## First line of `text` whose stripped content equals `anchor`; -1 if absent.
static func _find_line(text: String, anchor: String) -> int:
	var lines := text.split("\n")
	for i in lines.size():
		if lines[i].strip_edges() == anchor:
			return i
	return -1


## Mirror the editor: build the global-class registry from ProjectSettings (absent headless signal).
static func _ensure_global_class_registry() -> void:
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()


## Parsed once from the scenario file. Every case then edits parser.code_edit.text - the buffer, not
## the file - which is exactly the unsaved-editor state the sync exists for.
##
## HARNESS TRAP: assigning `code_edit.text` goes through TextEdit::set_text, which emits text_set and
## never text_changed - measured, and true both in and out of the scene tree (only incremental edits
## like set_line emit, and only while in the tree). So CodeEditParser._on_text_changed never fires,
## cache_dirty stays false, and a plain parse() silently early-exits: any case needing a real full
## parse must pass force=true. get_version() bumps either way, so sync_line_ranges() behaves here
## exactly as it does live.
static func _make_parser() -> GDScriptParser:
	_ensure_global_class_registry()
	var parser := GDScriptParser.new()
	parser.set_use_tree_sitter(true)
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.active_parser = parser
	parser.set_current_script(load(SCENARIO))
	parser.set_source_code(load(SCENARIO).source_code)
	parser.parse()
	return parser

#endregion
