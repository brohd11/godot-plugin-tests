extends SceneTree

const Parser = preload("res://addons/addon_lib/gdscript_parser/gdscript_parser.gd")
const LspSupport = preload("res://tests/gdscript_parser/lsp_support.gd")
const SOURCE = "extends RefCounted\nvar callbacks = [func(a: int): return a, func(b: String): return b]\nfunc run(captured: Color):\n\tvar before: int = 1\n\t[1].map(func(value: int):\n\t\tvar own: String = str(value)\n\t\t[2].map(func(inner: int): return inner + before)\n\t\treturn own\n\t)\n\tvar assigned = func(arg: int): return arg\n\tvar after: int = 2\n"

# _initialize(), not _init(): the main loop is null during _init(), so the native backend cannot attach.
func _initialize() -> void:
	_run_headless.call_deferred()


func _run_headless() -> void:
	var result:Dictionary = run_tests()
	print("\n".join(result.output))
	quit(1 if result.result else 0)

static func run_tests() -> Dictionary:
	var out:Array = []
	return {"result": _run(out), "output": out}

static func _check(out:Array, condition:bool, label:String) -> int:
	if condition:
		return 0
	out.append("FAIL: " + label)
	return 1

static func _run(out:Array) -> int:
	var failures:int = 0
	# Only _range_parity needs a backend; everything below exercises the parser itself, so it must run
	# whether or not the LSP is present.
	failures += _range_parity(out)
	var ucd = Parser.UClassDetail
	if ucd.global_class_registry.is_empty():
		ucd.global_class_registry = ucd.get_all_global_class_paths()
	var native := LspSupport.available()
	var modes: Array = [false, true] if native else [false]
	if not native:
		out.append("  " + LspSupport.skip_line("Inline Lambdas native mode"))
	for use_native:bool in modes:
		var parser = Parser.new()
		parser.set_parser_cache({})
		parser.set_use_native_backend(use_native)
		parser.active_parser = parser
		parser.set_current_script(load("res://tests/gdscript_parser/fixtures/gp_lambda_scope.gd"))
		parser.set_source_code(SOURCE)
		parser.parse(true)
		var root = parser.get_class_object("")
		var label:String = "native" if use_native else "plain"
		if use_native and not LspSupport.engaged(parser):
			failures += _check(out, false, label + ": backend requested but the parse fell back to plain text")
			continue
		failures += _check(out, root.lambdas.size() == 2, label + " class callbacks")
		var first = root.get_lambda_at_line(1, 35)
		var second = root.get_lambda_at_line(1, 65)
		failures += _check(out, first != null and second != null and first != second, label + " same-line positions")
		failures += _check(out, root.get_lambda_at_line(1) == null, label + " ambiguous line")
		if first != null and second != null:
			failures += _check(out, first.get_arguments().has("a") and not first.get_arguments().has("b"), label + " first signature")
			failures += _check(out, second.get_arguments().has("b") and not second.get_arguments().has("a"), label + " second signature")
		var function = root.functions.run
		failures += _check(out, function.get_lambdas().size() == 2, label + " function lambdas")
		var callback = root.get_lambda_at_line(5)
		failures += _check(out, callback != null, label + " inline body")
		if callback != null:
			failures += _check(out, callback.get_lambdas().size() == 1, label + " nested callback")
			callback.map_variables()
			failures += _check(out, callback.local_vars.size() == 1, label + " own locals: " + str(callback.local_vars.keys()))
			var scope:Dictionary = root.get_in_scope_vars_at_line(7)
			for expected:String in ["captured", "before", "value", "own"]:
				failures += _check(out, scope.has(expected), label + " captured " + expected)
			failures += _check(out, not scope.has("inner") and not scope.has("after"), label + " scope exit")
		failures += _check(out, function.local_vars.size() == 3, label + " parent locals: " + str(function.local_vars.keys()))
		failures += _check(out, parser.resolve_expression_to_type("a", 1, 35) == "int", label + " position type lookup")
		failures += _check(out, parser.resolve_expression_to_type("b", 1, 65) == "String", label + " second position type lookup")
		var cached:Dictionary = Parser.ScriptCache.serialize_class(root)
		var restored = Parser.ScriptCache.deserialize_class(cached, parser)
		failures += _check(out, restored.lambdas.size() == 2 and restored.get_lambda_at_line(1, 35) != null, label + " cache ranges")
		parser.set_source_code(SOURCE.replace("func(b: String): return b", "null"))
		root.get_lambda_at_line(1, 35)
		failures += _check(out, root.lambdas.size() == 1, label + " lazy refresh")
		parser.set_source_code("extends RefCounted\nvar a = func(): var own = \"; var fake = 1\"; return own\n")
		parser.parse(true)
		root = parser.get_class_object("")
		var inline_body = root.get_lambda("a")
		inline_body.map_variables()
		failures += _check(out, inline_body.local_vars.size() == 1, label + " inline locals ignore string semicolons")
		var inline_scope:Dictionary = root.get_in_scope_vars_at_line(1, [], 49)
		failures += _check(out, inline_scope.has("own") and not inline_scope.has("fake"), label + " inline local visible after semicolon")
		out.append("Checked inline lambdas: " + label)
	if failures == 0:
		out.append("PASS: inline lambda parser modes")
	return failures

static func _range_parity(out:Array) -> int:
	var failures:int = 0
	var fixtures:Array[String] = [
		SOURCE,
		"var a = [\"é\", func(): return 1, func named(x): return {\"x\": x}]\n",
		"func _init():\n\tvar f = func(\n\t\tx: int,\n\t\ty: String = \"a\"\n\t) -> int:\n\t\treturn x\n\tprint(f)\n",
		"var a = func():\n\tvar b = func(): return 1\n\treturn b\nclass Inner:\n\tvar callbacks = [func(): return 2]\n",
		"var value: int:\n\tget:\n\t\t[1].map(func(x): return x)\n\t\treturn 1\n",
		"func run():\n\treturn func(): return func(): return 1\n",
		"# func(): nope\nvar text = \"\"\"func():\n fake\"\"\"\nvar a = func(): return \"func(): \\\"ignored\\\"\" # func(): ignored\n",
	]
	# The oracle is the native service used directly: update_document()/document() need no CodeEdit and
	# no EditorNode, so this parity check does not depend on the editor-owned service node.
	var svc = LspSupport.new_service()
	if svc == null:
		out.append("  " + LspSupport.skip_line("Inline Lambdas range parity",
			"GDScriptLanguageService not registered"))
		return 0
	var revision:int = 0
	for source:String in fixtures:
		var scanned:Array = []
		_scan_ranges(Parser.CodeEditParser.LambdaScanner.scan(source), scanned)
		revision += 1
		var uri:String = "untitled:inline-lambda-parity/%d" % revision
		svc.update_document(uri, source, revision)
		var doc = svc.document(uri)
		if doc == null:
			failures += _check(out, false, "no document for %s" % uri)
			continue
		var data:Dictionary = doc.parse_script(uri)
		var extracted:Array = []
		for path:String in data.keys():
			var cls_data:Dictionary = data[path]
			_query_ranges(cls_data.get("lambdas", {}), extracted)
			for member:Dictionary in cls_data.get("members", {}).values():
				_query_ranges(member.get("lambdas", {}), extracted)
		svc.close_document(uri)
		scanned.sort()
		extracted.sort()
		failures += _check(out, scanned == extracted, "scanner ranges %s != %s for %s" % [scanned, extracted, source])
	return failures

static func _scan_ranges(entries:Array, result:Array) -> void:
	for entry:Dictionary in entries:
		result.append("%s:%s-%s:%s" % [entry.line_index, entry.column_index, entry.end_line, entry.end_column])
		_scan_ranges(entry._children, result)

## The native projection keys a lambda's start line as `line_index` (tree-sitter-gd called it `line`),
## and nests child lambdas under `lambdas`. Columns are byte columns on both sides, so the two range
## sets stay directly comparable with the scanner's.
static func _query_ranges(entries:Dictionary, result:Array) -> void:
	for entry:Dictionary in entries.values():
		result.append("%s:%s-%s:%s" % [entry.line_index, entry.column_index, entry.end_line, entry.end_column])
		_query_ranges(entry.get("lambdas", {}), result)
