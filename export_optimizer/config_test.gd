extends RefCounted

const Config = preload("res://addons/addon_lib/gdscript_optimizer/config.gd")

static func run_tests() -> Dictionary:
	var failures:Array = []
	var defaults := Config.from_file()
	if not defaults.errors.is_empty() or defaults.options != {"struct_mode": "tagged", "inline_mode": "tagged", "aggressive": false, "debug_tags": false}:
		failures.append("wrong config defaults")
	for mode:String in Config.MODES:
		var result := Config.from_dictionary({"struct_mode": mode, "inline_mode": mode, "aggressive": true})
		if not result.errors.is_empty() or result.options.struct_mode != mode or result.options.inline_mode != mode or not result.options.aggressive:
			failures.append("config override failed: " + mode)
	for invalid in [null, [], true, {"typo": true}, {"struct_mode": true}, {"inline_mode": "unknown"}, {"aggressive": 1},
		{"structs": true}, {"inline_functions": true}, {"struct_read_types": "as_casts"}, {"allow_ref_counted": true}]:
		var result := Config.from_dictionary(invalid)
		if result.errors.is_empty() or not result.options.is_empty():
			failures.append("invalid config accepted: " + str(invalid))
	var path := "user://optimizer-config-test.yaml"
	for source in ["aggressive: true\n", "structs: [\n", "structs: true\nstructs: false\n", "", "- true\n", "structs: true\n---\nstructs: false\n"]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(source)
		file.close()
		var result := Config.from_file(path)
		if result.errors.is_empty() != source.begins_with("aggressive"):
			failures.append("YAML validation failed: " + source)
	DirAccess.remove_absolute(path)
	if Config.from_file(path).errors.is_empty():
		failures.append("missing YAML accepted")
	if Config.from_file().options != defaults.options:
		failures.append("config leaked between loads")
	return {"result": failures.size(), "output": ["optimizer config: %d failures" % failures.size()] + failures}
