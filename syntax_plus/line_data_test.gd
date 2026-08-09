@tool
extends RefCounted
## HighlighterLogic._line_data_from_parser() must be a faithful projection of ParserClass /
## ParserFunc into the shape the C++ emits for sparse_parse()["lines"].
##
## That projection is what lets both update_class_members paths share one _refresh_helper_lines()
## traversal. The plain-text path is the no-extension fallback and never runs on a machine with
## GDScriptTreeSitter registered, so this suite is the only thing exercising it.
##
##     load("res://tests/syntax_plus/line_data_test.gd").run_tests()
##
## NOTE: this deliberately does NOT assert the two parse modes agree, because they do not. The
## plain-text path runs a function to the dedent, absorbing trailing blank and comment lines;
## tree-sitter ends it at the body node. Measured on the scenario at 4.6.3: root_func is 32..37 plain
## vs 32..33 tree-sitter. Each is correct for its path - that a function's end moves between parses
## is the whole reason GDScriptParser.sync_line_ranges() exists.
##
## IMPORTANT: a *running* editor caches the addon scripts via preloaded consts, so edits to them are
## NOT reliably hot-reloaded - use the clean-compile headless runner:
##     Godot --headless --path . --script res://tests/syntax_plus/run_headless.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser
const HighlighterLogic = preload("res://addons/syntax_plus/src/highlighter/highlighter_logic.gd")

const SCENARIO := "res://tests/syntax_plus/scenarios/scenario_spans.gd"

const LINE_INDEX = GDScriptParser.Keys.LINE_INDEX
const END_LINE = GDScriptParser.Keys.END_LINE


static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


static func _run(out: Array) -> int:
	var fails := 0
	fails += _run_mode(out, false)
	if ClassDB.class_exists("GDScriptTreeSitter"):
		fails += _run_mode(out, true)
	else:
		out.append("\n  (GDScriptTreeSitter not registered - tree-sitter mode skipped)")
	fails += _test_degenerate_class(out)

	out.append("\nSYNTAX PLUS LINE DATA: %s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	return fails


static func _run_mode(out: Array, use_tree_sitter: bool) -> int:
	var mode: String = "tree-sitter" if use_tree_sitter else "plain-text"
	out.append("\n=============== SYNTAX PLUS LINE DATA (%s) ===============" % mode)

	var parser := _make_parser(use_tree_sitter)
	var class_names := parser.get_classes()
	var line_data: Dictionary = HighlighterLogic._line_data_from_parser(parser, class_names)

	var fails := 0
	if class_names.size() < 4: # root + Outer + Outer.Inner + Sibling
		out.append("  [SETUP FAIL] expected the scenario's inner classes, got %s" % [class_names])
		return 1

	fails += _check(out, "covers_every_class",
		line_data.keys().size() == class_names.size(),
		"projected %s, parser has %s" % [line_data.keys(), class_names])

	for access_name:String in class_names:
		var class_obj = parser.get_class_object(access_name)
		var cls_data: Dictionary = line_data.get(access_name, {})
		var label: String = "<root>" if access_name.is_empty() else access_name

		# shape
		if not (cls_data.has(LINE_INDEX) and cls_data.has(END_LINE) and cls_data.has("functions")):
			fails += _check(out, "shape[%s]" % label, false, "got keys %s" % [cls_data.keys()])
			continue
		fails += _check(out, "shape[%s]" % label, true)

		# faithfulness: class span mirrors line_indexes
		var lines: PackedInt32Array = class_obj.line_indexes
		var want_start: int = lines[0] if not lines.is_empty() else 0
		var want_end: int = lines[lines.size() - 1] if not lines.is_empty() else want_start
		fails += _check(out, "class_span[%s]" % label,
			cls_data[LINE_INDEX] == want_start and cls_data[END_LINE] == want_end,
			"projected %d..%d, parser has %d..%d"
				% [cls_data[LINE_INDEX], cls_data[END_LINE], want_start, want_end])

		# faithfulness: every function, spanning declaration_line .. func_lines[-1]
		var funcs: Dictionary = cls_data["functions"]
		fails += _check(out, "covers_every_func[%s]" % label,
			funcs.keys().size() == class_obj.functions.keys().size(),
			"projected %s, parser has %s" % [funcs.keys(), class_obj.functions.keys()])

		for func_name in class_obj.functions.keys():
			if not funcs.has(func_name):
				fails += _check(out, "func_span[%s.%s]" % [label, func_name], false, "missing")
				continue
			var func_obj = class_obj.functions[func_name]
			var fl: PackedInt32Array = func_obj.func_lines
			var want_f_end: int = fl[fl.size() - 1] if not fl.is_empty() else func_obj.end_line
			var got: Dictionary = funcs[func_name]
			fails += _check(out, "func_span[%s.%s]" % [label, func_name],
				got[LINE_INDEX] == func_obj.declaration_line and got[END_LINE] == want_f_end,
				"projected %d..%d, parser has %d..%d"
					% [got[LINE_INDEX], got[END_LINE], func_obj.declaration_line, want_f_end])

	out.append("  %s: %d failed" % [mode, fails])
	return fails


## A ParserClass whose set_lines() was never called holds an empty PackedInt32Array. Indexing [0] on
## it crashes, which is what the old inline plain-text traversal did.
static func _test_degenerate_class(out: Array) -> int:
	out.append("\n  -- degenerate input")
	var parser := _make_parser(ClassDB.class_exists("GDScriptTreeSitter"))
	var bare = GDScriptParser.ParserClass.new()
	bare.access_path = "Bare"
	parser._class_access["Bare"] = bare

	var line_data: Dictionary = HighlighterLogic._line_data_from_parser(parser, ["Bare"])
	var cls_data: Dictionary = line_data.get("Bare", {})
	return _check(out, "empty_line_indexes_projects",
		cls_data.get(LINE_INDEX, -1) == 0 and cls_data.get(END_LINE, -1) == 0,
		"got %s" % [cls_data])


#region Harness internals ------------------------------------------------------------------

static func _check(out: Array, name: String, ok: bool, detail: String = "") -> int:
	if ok:
		out.append("  PASS  %s" % name)
		return 0
	out.append("  FAIL  %s  %s" % [name, detail])
	return 1


## Mirror the editor: build the global-class registry from ProjectSettings (absent headless signal).
static func _ensure_global_class_registry() -> void:
	var ucd = GDScriptParser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()


static func _make_parser(use_tree_sitter: bool) -> GDScriptParser:
	_ensure_global_class_registry()
	var parser := GDScriptParser.new()
	parser.set_use_tree_sitter(use_tree_sitter) # before parse(); forces the parse path under test
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.active_parser = parser
	parser.set_current_script(load(SCENARIO))
	parser.set_source_code(load(SCENARIO).source_code)
	parser.parse()
	return parser

#endregion
