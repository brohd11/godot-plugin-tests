extends RefCounted
const Parser = preload("res://addons/addon_lib/gdscript_parser/gdscript_parser.gd")
const PATH = "res://tests/gdscript_parser/fixtures/gp_base.gd"

static func run_tests() -> Dictionary:
	var out:Array = []
	return {"result": _run(out), "output": out}

static func _run(out:Array) -> int:
	var failures := 0
	var snapshots := {PATH: "extends RefCounted\nvar replacement:Array = []\n"}
	var dispatcher = Parser.new()
	dispatcher.set_use_native_backend(false)
	dispatcher.set_parser_cache({})
	dispatcher.set_source_provider(func(path:String): return snapshots.get(path))
	var first = dispatcher.get_parser_for_path(PATH)
	if first == null or first.get_class_object().get_member_type_rich("replacement").get("type") != "Array":
		out.append("snapshot did not override disk declarations")
		failures += 1
	if dispatcher.get_parser_for_path(PATH) != first:
		out.append("unchanged snapshot was not cached")
		failures += 1
	snapshots[PATH] = "extends RefCounted\nvar replacement:int = 2\n"
	var second = dispatcher.get_parser_for_path(PATH)
	if second == first or second.get_class_object().get_member_type_rich("replacement").get("type") != "int":
		out.append("changed snapshot reused stale metadata")
		failures += 1
	var disk = Parser.new()
	disk.set_use_native_backend(false)
	disk.set_parser_cache({})
	var original = disk.get_parser_for_path(PATH)
	if original.get_class_object().members.has("replacement"):
		out.append("snapshot leaked into an independent disk parser")
		failures += 1
	for parser in [first, second, original, dispatcher, disk]:
		parser.active_parser = null
		parser._parser_cache.clear()
		if is_instance_valid(parser.code_edit):
			parser.code_edit.free()
	out.append("source provider: %d failures" % failures)
	return failures
