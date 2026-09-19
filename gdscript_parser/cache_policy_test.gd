extends RefCounted

const Parser = preload("res://addons/addon_lib/gdscript_parser/gdscript_parser.gd")
const PATH = "res://tests/gdscript_parser/fixtures/cache_policy.gd"
const CACHE_DIR = "res://.godot/parser_cache_policy_test"

static func run_tests() -> Dictionary:
	var out:Array = []
	return {"result": _run(out), "output": out}

static func _run(out:Array) -> int:
	var failures:int = 0
	var parser = Parser.new()
	parser.set_use_native_backend(false)
	parser.set_parser_cache({})
	parser.set_parse_cache_dir(CACHE_DIR)
	parser.set_current_script(load(PATH))
	parser.set_source_code(FileAccess.get_file_as_string(PATH))
	parser.parse()
	var root_class = parser.get_class_object()
	var expected:Dictionary = root_class.get_member_type_rich("count").duplicate(true)
	var expected_recursive:String = root_class.get_function("recursive_value").get_return_type()
	if not parser.cache_enabled or root_class._resolve_cache.is_empty() or not parser.write_cache():
		out.append("FAIL enabled cache did not populate/persist")
		failures += 1
	var cached = parser.read_cache(PATH)
	if cached == null or cached.state != Parser.STATE_CACHED_RESOLVED:
		out.append("FAIL enabled disk cache did not rehydrate")
		failures += 1
	if cached != null:
		cached.set_cache_enabled(false)
		if cached.state != Parser.STATE_LIVE or cached.get_class_object().get_member_type("count") != "int":
			out.append("FAIL disabling a rehydrated parser did not rebuild live state")
			failures += 1
	parser.set_cache_enabled(false)
	if parser.read_cache(PATH) != null or parser.write_cache() or Parser.ScriptCache.write(parser):
		out.append("FAIL disabled disk cache was accessed")
		failures += 1
	for _repeat in 2:
		var result:Dictionary = root_class.get_member_type_rich("count")
		if result != expected or not root_class._resolve_cache.is_empty():
			out.append("FAIL uncached member result differs or was stored")
			failures += 1
		result.type = "poison"
		parser.get_string_map("var value = 42")
		if not parser.code_edit_parser.string_map_cache.is_empty():
			out.append("FAIL disabled string map cache was populated")
			failures += 1
	var function = root_class.get_function("local_value")
	function.parse()
	for key in function.local_vars:
		var first:Dictionary = function.get_local_var_type_rich(key)
		if first.type != "int":
			out.append("FAIL uncached local inference")
			failures += 1
		first.type = "poison"
		if function.get_local_var_type_rich(key).type != "int" or not function._cache.is_empty():
			out.append("FAIL local inference reused a result")
			failures += 1
	var local_return:String = function.get_return_type()
	var recursive_return:String = root_class.get_function("recursive_value").get_return_type()
	if local_return != "int" or recursive_return != expected_recursive:
		out.append("FAIL uncached return inference / recursion guard: %s / %s" % [local_return, recursive_return])
		failures += 1
	var dispatcher = Parser.new()
	dispatcher.set_use_native_backend(false)
	dispatcher.set_parse_cache_dir(CACHE_DIR)
	dispatcher.set_cache_enabled(false)
	var first = dispatcher.get_parser_for_path(PATH)
	var second = dispatcher.get_parser_for_path(PATH)
	if first == second or first.cache_enabled or second.cache_enabled or first.state != Parser.STATE_LIVE:
		out.append("FAIL uncached dependency policy / freshness")
		failures += 1
	if first.get_class_object().get_member_type("count") != "int":
		out.append("FAIL uncached dependency lost its parser owner")
		failures += 1
	dispatcher.set_source_provider(func(_path:String): return "extends RefCounted\nvar count:String = 'snapshot'\n")
	var snapshot = dispatcher.get_parser_for_path(PATH)
	if snapshot.get_class_object().get_member_type("count") != "String" or snapshot.cache_enabled:
		out.append("FAIL uncached source provider")
		failures += 1
	dispatcher.set_cache_enabled(true)
	dispatcher.set_parser_cache({})
	var reusable = dispatcher.get_parser_for_path(PATH)
	if reusable != dispatcher.get_parser_for_path(PATH):
		out.append("FAIL enabled dependency cache no longer reuses snapshots")
		failures += 1
	var nested_path:String = "res://tests/gdscript_parser/fixtures/only_inner_classes.gd"
	var nested = Parser.new()
	nested.set_use_native_backend(false)
	nested.set_cache_enabled(false)
	nested.set_current_script(load(nested_path))
	nested.set_source_code(FileAccess.get_file_as_string(nested_path))
	nested.parse()
	if nested.get_class_at_line(0) != "First" or nested.get_class_object("First").get_member_type("VALUE") != "int":
		out.append("FAIL script containing only inner classes")
		failures += 1
	if nested.get_class_object().get_member_type("Second") != nested_path + ".Second":
		out.append("FAIL root member resolution without root-owned lines")
		failures += 1
	for instance in [parser, cached, dispatcher, first, second, snapshot, reusable, nested]:
		if instance == null:
			continue
		instance.clear_parser_cache()
		if is_instance_valid(instance.code_edit):
			instance.code_edit.free()
	out.append("Cache policy: %d failures" % failures)
	return failures
