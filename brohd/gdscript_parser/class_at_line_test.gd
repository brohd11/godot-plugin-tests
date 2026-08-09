@tool
extends RefCounted
## get_class_at_line() must return the INNERMOST class owning a line, independent of _class_access
## key order.
##
## Regression guard: the tree-sitter parse gives every class a full contiguous range
## (code_edit_parser.gd, `range(class_start, class_end + 1)`, root forced to 0), so the root class
## also contains every inner class's lines. The old first-match loop therefore returned whichever
## class happened to sit first in the dict - and that order is NOT parse order: _set_class_obj()
## writes into the existing _class_access, so an order seeded earlier (restored cache classes, or a
## plain-text parse whose map starts as {"": []}) outlives every later re-parse. With the root first,
## every inner-class line resolved to the root, and any cross-script resolve that anchors on
## ParserClass.declaration_line (_process_external_identifier -> ClassData) silently returned "".
##
##     load("res://tests/brohd/gdscript_parser/class_at_line_test.gd").run_tests()
##
## IMPORTANT: a *running* editor caches the parser scripts via preloaded consts, so edits to them are
## NOT reliably hot-reloaded - use the clean-compile headless runner:
##     Godot --headless --path . --script res://tests/brohd/gdscript_parser/run_all_headless.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser

const DIR := "res://tests/brohd/gdscript_parser/"
const BASIC := DIR + "scenarios/scenario_basic.gd"


## Each case: an `anchor` line of scenario_basic.gd and the access path that owns it. Anchors are
## matched whole (stripped) so they stay readable and survive line-number drift.
static func _cases() -> Array:
	return [
		# inner class body - the shape that broke
		{"name": "inner_class_decl",   "anchor": "class GpAlert:",                "expected": "GpAlert"},
		{"name": "inner_class_member", "anchor": "func all_valid() -> AlertType:", "expected": "GpAlert"},
		# two-level nesting: the middle class must win over both the root and its own parent
		{"name": "nested_mid_decl",    "anchor": "class Mid:",                    "expected": "Outer.Mid"},
		{"name": "nested_mid_member",  "anchor": "enum MidNum { A, B }",          "expected": "Outer.Mid"},
		# same-name nesting: the inner DupName owns its body, not the outer one
		{"name": "same_name_inner",    "anchor": "enum DupNum { A, B }",          "expected": "DupName.DupName"},
		# root-owned lines must stay root-owned
		{"name": "root_enum",          "anchor": "enum TopEnum { X, Y }",         "expected": ""},
		{"name": "root_func_body",     "anchor": "var ad := GpAlert.new()",       "expected": ""},
	]


static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


## Both parse paths: plain text (root range excludes inner classes) and tree-sitter (root range spans
## the whole file). Only the latter can hit the ambiguity, but the lookup must agree in both.
static func _run(out: Array) -> int:
	var fails := 0
	fails += _run_mode(out, false)
	if ClassDB.class_exists("GDScriptTreeSitter"):
		fails += _run_mode(out, true)
	else:
		out.append("\n  (GDScriptTreeSitter not registered - tree-sitter mode skipped)")
	out.append("\nCLASS AT LINE: %s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	return fails


static func _run_mode(out: Array, use_tree_sitter: bool) -> int:
	var mode_label: String = "tree-sitter" if use_tree_sitter else "plain-text"
	out.append("\n=============== CLASS AT LINE (%s) ===============" % mode_label)

	var parser := _make_parser(BASIC, use_tree_sitter)
	var lines := PackedStringArray(load(BASIC).source_code.split("\n"))

	var fails := 0
	# Pass 1: natural (parse) order. Pass 2: the same parser with the root key re-inserted FIRST,
	# which is what a parser that restored its classes from cache ends up holding. Same answers.
	for pass_idx in 2:
		if pass_idx == 1:
			_reorder_root_first(parser)
			out.append("  -- _class_access reordered root-first: %s" % [parser.get_classes()])

		for case in _cases():
			var line := _find_line(lines, case.anchor)
			if line == -1:
				fails += 1
				out.append("  [SETUP FAIL] %s: anchor not found '%s'" % [case.name, case.anchor])
				continue
			var got := parser.get_class_at_line(line)
			if got == case.expected:
				out.append("  PASS  %-18s line %-3d -> '%s'" % [case.name, line, got])
			else:
				fails += 1
				out.append("  FAIL  %-18s line %-3d expected '%s' got '%s'"
					% [case.name, line, case.expected, got])

		# End-to-end: the failure the reorder used to cause. all_valid() is declared on the inner
		# GpAlert; resolving it at GpAlert's declaration_line is exactly what a cross-script lookup
		# does (_process_external_identifier), and it needs ClassData to land on GpAlert.
		var gp_alert = parser.get_class_object("GpAlert")
		if gp_alert == null:
			fails += 1
			out.append("  [SETUP FAIL] resolve: no class object for 'GpAlert'")
		else:
			var resolved: String = parser.resolve_expression_to_type("all_valid()", gp_alert.declaration_line)
			var expected := "%s.GpAlert::AlertType%sEnum" % [BASIC, GDScriptParser.Keys.TYPE_DELIM]
			if resolved == expected:
				out.append("  PASS  %-18s -> '%s'" % ["resolve_inner_func", resolved])
			else:
				fails += 1
				out.append("  FAIL  %-18s expected '%s' got '%s'"
					% ["resolve_inner_func", expected, resolved])

	out.append("  %s: %d failed" % [mode_label, fails])
	return fails


#region Harness internals ------------------------------------------------------------------

## Re-seed _class_access with the root ("") first, preserving the class objects (and so their
## line_indexes) exactly. Reproduces the live-editor ordering without needing the disk cache.
static func _reorder_root_first(parser: GDScriptParser) -> void:
	var objs := {}
	for access_path in parser.get_classes():
		objs[access_path] = parser.get_class_object(access_path)
	var reordered := {}
	reordered[""] = objs.get("")
	for access_path in objs.keys():
		if access_path != "":
			reordered[access_path] = objs[access_path]
	parser.clear_current_class()
	parser.set_class_objs(reordered)


## First line whose stripped text equals `anchor`; -1 if absent.
static func _find_line(lines: PackedStringArray, anchor: String) -> int:
	for i in lines.size():
		if lines[i].strip_edges() == anchor:
			return i
	return -1


## Mirror the editor: build the global-class registry from ProjectSettings (absent headless signal).
static func _ensure_global_class_registry() -> void:
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()


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
