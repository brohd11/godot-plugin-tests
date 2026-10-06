extends SceneTree
## Nameless enum entries and var-assigned lambdas. Both parse paths must produce tree-sitter's shape,
## entries must resolve to int without the check_member_line reparse fallback, and lambdas must
## survive the disk cache.
##
##     Godot --headless --path . --script res://tests/gdscript_parser/nameless_enum_lambda_test.gd

const LspSupport = preload("res://tests/gdscript_parser/lsp_support.gd")
const Keys = GDScriptParser.Keys

const FIXTURE := "res://tests/gdscript_parser/fixtures/gp_enum_lambda.gd"
const TEST_CACHE_DIR := "res://.godot/addons/gdscript_parser/parse_cache_enum_lambda_test"

# entry name -> [line, column, assignment]
const ROOT_ENTRIES := {
	"A": [3, 7, "0"], "B": [3, 10, "3"], "C": [3, 17, "B + 1"],
	"NEG": [5, 1, "-3"], "NEXT": [6, 1, "NEG + 1"], "BITS": [7, 1, "1 << 4"], "AFTER": [8, 1, "BITS + 1"],
}
const LOCAL_LAMBDA := "local_lambda-26-1"
const ENTRY_FIELDS := [Keys.MEMBER_TYPE, Keys.MEMBER_NAME, Keys.LINE_INDEX, Keys.COLUMN_INDEX, Keys.TYPE,
	Keys.HAS_STATIC_TYPE, Keys.ASSIGNMENT, Keys.ACCESS_PATH, Keys.SCRIPT_PATH]


# _initialize(), not _init(): the main loop is null during _init(), so the native backend cannot attach.
func _initialize() -> void:
	_run_headless.call_deferred()


func _run_headless() -> void:
	var res := run_tests()
	print("\n".join(res.output))
	quit(1 if res.result > 0 else 0)


static func run_tests() -> Dictionary:
	var out: Array = []
	return {"result": _run(out), "output": out}


static func _run(out: Array) -> int:
	_ensure_global_class_registry()
	_clear_test_cache_dir()
	# The native backend needs the editor-owned LSP service; it runs from the editor console.
	var native := LspSupport.available()
	var modes: Array = [false, true] if native else [false]
	if not native:
		out.append("  " + LspSupport.skip_line("Nameless Enum + Lambda native mode"))

	var failures := 0
	for use_native in modes:
		var label: String = "native" if use_native else "plain-text"
		var parser := _make_parser(use_native)
		if use_native and not LspSupport.engaged(parser):
			failures += _expect(out, false, "%s: native backend requested but the parse fell back to plain text" % label)
			continue
		failures += _check_enums(out, parser, label)
		failures += _check_lambdas(out, parser, label)
		_clear_test_cache_dir() # each mode writes and reads its own .bin
		failures += _check_cache(out, use_native)
	if native:
		failures += _check_parity(out)
	_clear_test_cache_dir()

	out.append("")
	if failures == 0:
		out.append("NAMELESS ENUM + LAMBDA: ALL PASS")
	else:
		out.append("NAMELESS ENUM + LAMBDA: %d FAILURE(S)" % failures)
	return failures


static func _check_enums(out: Array, parser: GDScriptParser, label: String) -> int:
	var f := 0
	var root = parser.get_class_object("")
	for entry_name in ROOT_ENTRIES:
		var data = root.constants.get(entry_name)
		if data is not Dictionary:
			f += _expect(out, false, "%s: root constant '%s' missing" % [label, entry_name])
			continue
		var got := [data.get(Keys.LINE_INDEX), data.get(Keys.COLUMN_INDEX), data.get(Keys.ASSIGNMENT)]
		f += _expect(out, got == ROOT_ENTRIES[entry_name],
			"%s: '%s' [line, column, assignment] %s != %s" % [label, entry_name, got, ROOT_ENTRIES[entry_name]])
		f += _expect(out, data.get(Keys.MEMBER_TYPE) == Keys.MEMBER_TYPE_CONST and data.get(Keys.TYPE) == &"int"
			and data.get(Keys.HAS_STATIC_TYPE) == true, "%s: '%s' is not a static int const: %s" % [label, entry_name, data])
	f += _expect(out, root.has_enum("Named") and not root.constants.has("HIDDEN"), "%s: named enum not kept as one member" % label)
	f += _expect(out, root.constants.has("ORDINARY"), "%s: ordinary const dropped" % label)

	var inner = parser.get_class_object("Inner")
	f += _expect(out, inner != null and inner.constants.has("INNER_A") and inner.constants.has("A"),
		"%s: Inner missing its own or outer entries" % label)

	var cep = parser.get_code_edit_parser()
	for entry_name in ["A", "C", "NEXT", "AFTER"]:
		var data: Dictionary = root.constants.get(entry_name, {})
		# rebuild=false: before the fix this failed and fell back to a full parse_text()
		f += _expect(out, cep.check_member_line(Keys.MEMBER_TYPE_CONST, entry_name, data.get(Keys.LINE_INDEX, -1),
			data.get(Keys.COLUMN_INDEX, 0), false), "%s: check_member_line rejected entry '%s'" % [label, entry_name])
		var type: String = root.get_member_type(entry_name)
		f += _expect(out, type == "int", "%s: '%s' resolved to '%s', expected int" % [label, entry_name, type])
	if inner != null:
		var inner_type: String = inner.get_member_type("INNER_B")
		f += _expect(out, inner_type == "int", "%s: Inner 'INNER_B' resolved to '%s'" % [label, inner_type])
	# starts with the name but isn't inside an enum (a stale line index)
	f += _expect(out, not cep.is_enum_entry_line("return", 21, 1), "%s: non-enum line accepted as entry" % label)
	f += _expect(out, not cep.check_member_line(Keys.MEMBER_TYPE_CONST, "A", 21, 1, false), "%s: stale entry line accepted" % label)

	if f == 0:
		out.append("  PASS  enums (%s)" % label)
	return f


static func _check_lambdas(out: Array, parser: GDScriptParser, label: String) -> int:
	var f := 0
	var root = parser.get_class_object("")
	var typed = root.get_lambda("typed_lambda")
	var one = root.get_lambda("one_liner")
	var real = root.get_function("real")
	var with_locals = root.get_function("with_locals")
	f += _expect(out, root.lambdas.size() == 2, "%s: member lambdas %s" % [label, root.lambdas.keys()])
	if typed == null or one == null or real == null or with_locals == null:
		return f + _expect(out, false, "%s: lambda or function objects missing" % label)

	f += _expect(out, typed.is_lambda and [typed.declaration_line, typed.end_line] == [13, 15],
		"%s: typed_lambda range %s" % [label, [typed.declaration_line, typed.end_line]])
	f += _expect(out, [one.declaration_line, one.end_line] == [17, 17], "%s: one_liner range %s" % [label, [one.declaration_line, one.end_line]])
	f += _expect(out, not root.members["typed_lambda"].has(Keys.LAMBDA), "%s: lambda sub-dict left in member data" % label)
	f += _expect(out, root.get_function("typed_lambda") == null, "%s: lambda registered as a function" % label)

	# same signature as real(), so the args must normalize identically
	f += _expect(out, _arg_shape(typed.get_arguments()) == _arg_shape(real.get_arguments()),
		"%s: typed_lambda args %s != real() %s" % [label, _arg_shape(typed.get_arguments()), _arg_shape(real.get_arguments())])
	f += _expect(out, typed.get_return_type(false) == real.get_return_type(false),
		"%s: typed_lambda return '%s' != real() '%s'" % [label, typed.get_return_type(false), real.get_return_type(false)])
	f += _expect(out, one.get_arguments().has("x") and one.get_return_type(false) == "x",
		"%s: one_liner args %s return '%s'" % [label, one.get_arguments().keys(), one.get_return_type(false)])

	var local_lambdas: Dictionary = with_locals.get_lambdas()
	var lam = local_lambdas.get(LOCAL_LAMBDA)
	f += _expect(out, lam != null, "%s: local lambdas %s" % [label, local_lambdas.keys()])
	if lam != null:
		f += _expect(out, [lam.declaration_line, lam.end_line] == [26, 28], "%s: local lambda range %s" % [label, [lam.declaration_line, lam.end_line]])
		f += _expect(out, lam.get_arguments().has("n") and lam.get_return_type(false) == "int",
			"%s: local lambda args %s return '%s'" % [label, lam.get_arguments().keys(), lam.get_return_type(false)])
		lam.map_variables()
		f += _expect(out, lam.local_vars.has("nested_local-27-2"), "%s: lambda locals %s" % [label, lam.local_vars.keys()])
		f += _expect(out, root.get_lambda_at_line(27) == lam, "%s: get_lambda_at_line(27) missed the local lambda" % label)
	var parent_locals: Array = with_locals.local_vars.keys()
	f += _expect(out, not parent_locals.any(func(k): return str(k).begins_with("nested_local")),
		"%s: lambda body local leaked into parent %s" % [label, parent_locals])
	f += _expect(out, parent_locals.any(func(k): return str(k).begins_with("after")),
		"%s: local after the lambda not mapped %s" % [label, parent_locals])
	f += _expect(out, root.get_lambda_at_line(14) == typed and root.get_lambda_at_line(21) == null,
		"%s: get_lambda_at_line on member lambda / plain func" % label)

	var inner = parser.get_class_object("Inner")
	f += _expect(out, inner != null and inner.get_lambda("inner_lambda") != null, "%s: Inner.inner_lambda missing" % label)

	if f == 0:
		out.append("  PASS  lambdas (%s)" % label)
	return f


## Plain-text must fold into the same data the native backend emits.
static func _check_parity(out: Array) -> int:
	var f := 0
	var plain = _make_parser(false)
	var native = _make_parser(true)
	for access_path in ["", "Inner"]:
		var p_consts: Dictionary = plain.get_class_object(access_path).constants
		var t_consts: Dictionary = native.get_class_object(access_path).constants
		f += _expect(out, _str_keys(p_consts) == _str_keys(t_consts),
			"parity: '%s' constant names %s != %s" % [access_path, _str_keys(p_consts), _str_keys(t_consts)])
		for entry_name in t_consts:
			# only enum entries: plain-text never stored type/assignment for ordinary consts
			if not (entry_name in ROOT_ENTRIES or entry_name in ["INNER_A", "INNER_B"]) or not p_consts.has(entry_name):
				continue
			var t_data: Dictionary = t_consts[entry_name]
			for field in ENTRY_FIELDS:
				f += _expect(out, str(p_consts[entry_name].get(field)) == str(t_data.get(field)),
					"parity: '%s' %s plain '%s' != ts '%s'" % [entry_name, field, p_consts[entry_name].get(field), t_data.get(field)])

	var p_root = plain.get_class_object("")
	var t_root = native.get_class_object("")
	for lambda_name in t_root.lambdas:
		var t_lam = t_root.lambdas[lambda_name]
		var p_lam = p_root.lambdas.get(lambda_name)
		f += _expect(out, p_lam != null and [p_lam.declaration_line, p_lam.end_line] == [t_lam.declaration_line, t_lam.end_line]
			and _arg_shape(p_lam.get_arguments()) == _arg_shape(t_lam.get_arguments()),
			"parity: lambda '%s' differs between modes" % lambda_name)
	var p_local: Dictionary = p_root.get_function("with_locals").get_lambdas()
	var t_local: Dictionary = t_root.get_function("with_locals").get_lambdas()
	f += _expect(out, _str_keys(p_local) == _str_keys(t_local), "parity: local lambdas %s != %s" % [_str_keys(p_local), _str_keys(t_local)])

	if f == 0:
		out.append("  PASS  plain-text / native parity")
	return f


static func _check_cache(out: Array, use_native: bool) -> int:
	var f := 0
	var parser := _make_parser(use_native)
	var root = parser.get_class_object("")
	var want_args := _arg_shape(root.get_lambda("typed_lambda").get_arguments()) # populate before writing
	root.get_function("with_locals").get_lambdas()
	if not parser.write_cache():
		return _expect(out, false, "cache: write_cache() returned false")
	var rehydrated: GDScriptParser = parser.read_cache(FIXTURE)
	if rehydrated == null:
		return _expect(out, false, "cache: read_cache() returned null")

	var r_root = rehydrated.get_class_object("")
	var typed = r_root.get_lambda("typed_lambda")
	f += _expect(out, typed != null and typed.is_lambda and [typed.declaration_line, typed.end_line] == [13, 15],
		"cache: typed_lambda not restored")
	if typed != null:
		f += _expect(out, _arg_shape(typed.arguments) == want_args, "cache: typed_lambda args %s != %s" % [_arg_shape(typed.arguments), want_args])
	f += _expect(out, r_root.get_function("with_locals").lambdas.has(LOCAL_LAMBDA), "cache: local lambda not restored")
	f += _expect(out, str(r_root.constants.get("NEXT", {}).get(Keys.ASSIGNMENT)) == "NEG + 1", "cache: enum entry not restored")

	if f == 0:
		out.append("  PASS  cache round-trip (%s)" % ("native" if use_native else "plain-text"))
	return f


static func _arg_shape(args: Dictionary) -> Dictionary:
	var shape := {}
	for arg_name in args:
		var arg: Dictionary = args[arg_name]
		shape[str(arg_name)] = [str(arg.get(Keys.TYPE)), str(arg.get(Keys.ASSIGNMENT)), arg.get(Keys.HAS_STATIC_TYPE)]
	return shape


static func _str_keys(dict: Dictionary) -> Array:
	var keys := []
	for k in dict:
		keys.append(str(k))
	keys.sort()
	return keys


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
	parser.set_parse_cache_dir(TEST_CACHE_DIR)
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


static func _clear_test_cache_dir() -> void:
	if not DirAccess.dir_exists_absolute(TEST_CACHE_DIR):
		return
	var dir := DirAccess.open(TEST_CACHE_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
