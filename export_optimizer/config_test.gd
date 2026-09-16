extends RefCounted

const Config = preload("res://addons/addon_lib/gdscript_optimizer/config.gd")

static func run_tests() -> Dictionary:
	var failures:Array = []
	var defaults := Config.from_file()
	if not defaults.errors.is_empty() or defaults.options != {"structs": true, "inline_functions": true,
		"scalar_replacement": true, "struct_read_types": 1, "allow_ref_counted": false}:
		failures.append("wrong config defaults")
	for mode in Config.READ_MODES:
		var result := Config.from_dictionary({"struct_read_types": mode, "allow_ref_counted": true})
		if not result.errors.is_empty() or result.options.struct_read_types != Config.READ_MODES.find(mode) or not result.options.allow_ref_counted:
			failures.append("config override failed: " + mode)
	for invalid in [null, [], true, {"typo": true}, {"structs": "true"}, {"scalar_replacement": 1},
		{"struct_read_types": 1}, {"struct_read_types": "unknown"}, {"allow_ref_counted": "yes"}]:
		var result := Config.from_dictionary(invalid)
		if result.errors.is_empty() or not result.options.is_empty():
			failures.append("invalid config accepted: " + str(invalid))
	var path := "user://optimizer-config-test.yaml"
	for source in ["allow_ref_counted: true\n", "structs: [\n", "structs: true\nstructs: false\n", "", "- true\n", "structs: true\n---\nstructs: false\n"]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(source)
		file.close()
		var result := Config.from_file(path)
		if result.errors.is_empty() != source.begins_with("allow_ref_counted"):
			failures.append("YAML validation failed: " + source)
	DirAccess.remove_absolute(path)
	if Config.from_file(path).errors.is_empty():
		failures.append("missing YAML accepted")
	if Config.from_file().options != defaults.options:
		failures.append("config leaked between loads")
	return {"result": failures.size(), "output": ["optimizer config: %d failures" % failures.size()] + failures}
