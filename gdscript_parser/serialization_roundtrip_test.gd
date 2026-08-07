extends SceneTree
## Round-trip test for the persistent parse cache (to_cache_dict / write_cache / read_cache).
##
## Builds a live parser per fixture, forces member + function + local resolution to populate the
## resolve caches, serializes to disk, rehydrates a fresh CACHED_RESOLVED parser, and asserts the
## re-emitted cache dict is byte-for-byte identical - proving no data is lost and no live object
## leaks into the plain-data file (store_var full_objects=false would otherwise error).
##
##     Godot --headless --path . --script res://tests/gdscript_parser/serialization_roundtrip_test.gd

const GDScriptParser = preload("uid://c4465kdwgj042") #! resolve ALibRuntime.Utils.UGDScript.Parser

const DIR := "res://tests/gdscript_parser/"
const TEST_CACHE_DIR := "res://.godot/addons/gdscript_parser/parse_cache_test"
const FIXTURES := [
	DIR + "scenarios/scenario_inheritance.gd",
	DIR + "scenarios/scenario_basic.gd",
	DIR + "fixtures/gp_service.gd",
	DIR + "fixtures/gp_derived.gd",
]

# Headless entry point (`--script serialization_roundtrip_test.gd`). quit() lives ONLY here so the static
# path below is safe to call from the editor console / aggregator without killing the editor.
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
	_clear_test_cache_dir()
	var failures := 0
	for path in FIXTURES:
		failures += _run_case(out, path)
	out.append("")
	if failures == 0:
		out.append("SERIALIZATION ROUND-TRIP: ALL PASS (%d fixtures)" % FIXTURES.size())
	else:
		out.append("SERIALIZATION ROUND-TRIP: %d FAILURE(S)" % failures)
	_clear_test_cache_dir()
	return failures


static func _run_case(out: Array, script_path:String) -> int:
	var parser := _make_parser(script_path)
	_force_resolve(parser)
	var before := _emit(parser)

	if not parser.write_cache():
		out.append("  FAIL  %s -> write_cache() returned false" % script_path)
		return 1

	var rehydrated:GDScriptParser = parser.read_cache(script_path)
	if rehydrated == null:
		out.append("  FAIL  %s -> read_cache() returned null" % script_path)
		return 1
	if rehydrated.state != GDScriptParser.STATE_CACHED_RESOLVED:
		out.append("  FAIL  %s -> rehydrated parser not in CACHED_RESOLVED state" % script_path)
		return 1

	var after := _emit(rehydrated)
	var diff := _first_diff(before, after, "")
	if diff != "":
		out.append("  FAIL  %s -> mismatch at %s" % [script_path, diff])
		return 1

	out.append("  PASS  %s  (%d classes)" % [script_path, before.size()])
	return 0


## Emit the flat cache-dict for every class the parser knows about.
static func _emit(parser:GDScriptParser) -> Dictionary:
	var out := {}
	for access_path in parser.get_classes():
		var class_obj = parser.get_class_object(access_path)
		out[access_path] = GDScriptParser.ScriptCache.serialize_class(class_obj)
	return out


## Touch every member / function / local so the resolve caches are populated before serializing.
static func _force_resolve(parser:GDScriptParser) -> void:
	for access_path in parser.get_classes():
		var class_obj = parser.get_class_object(access_path)
		var names := []
		names.append_array(class_obj.members.keys())
		names.append_array(class_obj.constants.keys())
		names.append_array(class_obj.inner_classes.keys())
		names.append_array(class_obj.functions.keys())
		for name in names:
			@warning_ignore("unsafe_method_access")
			class_obj.get_member_type_rich(name)
		for fname in class_obj.functions.keys():
			var func_obj = class_obj.functions[fname]
			func_obj.map_variables()
			func_obj.get_return_type_rich()
			for local_name in func_obj.local_vars.keys():
				func_obj.get_local_var_type_rich(local_name)


static func _make_parser(script_path:String) -> GDScriptParser:
	var parser := GDScriptParser.new()
	parser.set_autoload_cache()
	parser.set_parser_cache({})
	parser.set_parser_cache_size(40)
	parser.set_parse_cache_dir(TEST_CACHE_DIR)
	parser.active_parser = parser
	parser.set_current_script(load(script_path))
	parser.set_source_code(load(script_path).source_code)
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


## Recursive deep compare returning the path of the first divergence, or "" if identical.
static func _first_diff(a, b, path:String) -> String:
	if typeof(a) != typeof(b):
		return "%s (type %d != %d)" % [path, typeof(a), typeof(b)]
	if a is Dictionary:
		if a.size() != b.size():
			return "%s (dict size %d != %d)" % [path, a.size(), b.size()]
		for k in a.keys():
			if not b.has(k):
				return "%s/%s (key missing in rehydrated)" % [path, str(k)]
			var d := _first_diff(a[k], b[k], "%s/%s" % [path, str(k)])
			if d != "":
				return d
		return ""
	if a is Array or a is PackedInt32Array or a is PackedStringArray:
		if a.size() != b.size():
			return "%s (array size %d != %d)" % [path, a.size(), b.size()]
		for i in a.size():
			var d := _first_diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if a != b:
		return "%s (%s != %s)" % [path, str(a), str(b)]
	return ""
