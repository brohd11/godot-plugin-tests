extends SceneTree

const ExportData = preload("res://addons/plugin_exporter/src/class/export/export_data.gd")
const Fixture = preload("res://tests/plugin_exporter/export_fixture_test.gd")
const CONFIG = "res://addons/plugin_exporter_test/export_ignore/plugin_export.yml"

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var root:String = OS.get_cmdline_user_args()[0]
	var yaml := YAMLParser.new()
	if yaml.parse_file(CONFIG) != OK:
		quit(1)
		return
	var config:Dictionary = yaml.data
	config.export_root = root.path_join("packages")
	config.plugin_folder = "fixtures"
	config.pre_script = ""
	config.post_script = ""
	# The partial override below must inherit this non-default debug setting.
	config.options.parser_settings.parse_gd.optimizer = {"debug_tags": true}
	for entry:Dictionary in config.exports:
		entry.parser_overide_settings["parse_gd"] = {"optimizer": {"debug_tags": false}}
	var base:Dictionary = config.exports[0].duplicate(true)
	for variant:String in ["disabled", "inline-off", "references", "struct-only"]:
		var entry:Dictionary = base.duplicate(true)
		entry.export_name = variant
		var options:Dictionary = {"enabled": false, "unknown": true} if variant == "disabled" else {}
		if variant == "inline-off":
			options.inline_mode = "off"
		elif variant == "references":
			options.aggressive = true
			options.debug_tags = true
		elif variant == "struct-only":
			options = {"inline_mode": "off", "struct_mode": "tagged"}
		entry.parser_overide_settings = {"parse_gd": {"optimizer": options}}
		config.exports.append(entry)
	var path := root.path_join("plugin_export.yml")
	YAMLParser.dump_to_file(config, path)
	var version := FileAccess.open(root.path_join("version.cfg"), FileAccess.WRITE)
	version.store_string('[plugin]\nversion="0.1.0"\n')
	version.close()
	var data = ExportData.new(path)
	if not data.data_valid:
		quit(1)
		return
	var manifest:Array = []
	for entry in data.exports:
		entry.file_parser.pre_export()
		if not entry.export_valid:
			quit(1)
			return
		entry.export_files()
		if not entry.export_valid:
			quit(1)
			return
		entry.write_export_data_file()
		entry.update_plugin_cfg()
		var optimization = entry.file_parser.optimization
		manifest.append({"name": entry.export_name.trim_suffix("/"), "dir": entry.export_dir_path,
			"install": entry.export_folder, "stats": optimization.stats.duplicate(true)})
		var key:String = entry.export_name.get_slice("-0", 0)
		if key.begins_with("plugin-exporter-test") or key.begins_with("pet-"):
			Fixture._dirs[key] = entry.export_dir_path
			Fixture._installs[entry.export_dir_path] = "res://" + entry.export_folder
	Fixture._failures = []
	Fixture._passed = 0
	Fixture._test_struct()
	Fixture._test_optimizer()
	Fixture._test_no_cross_contamination()
	Fixture._test_every_reference_resolves()
	_test_failures(data, root)
	for failure in Fixture._failures:
		printerr(failure)
	var output := FileAccess.open(root.path_join("manifest.json"), FileAccess.WRITE)
	output.store_string(JSON.stringify(manifest))
	output.close()
	print("OPTIMIZER_EXPORT_ASSERTIONS ", Fixture._passed, " passed, ", Fixture._failures.size(), " failed")
	quit(0 if Fixture._failures.is_empty() else 1)


func _test_failures(data, root:String) -> void:
	var entry = data.exports[0]
	var optimization = entry.file_parser.optimization
	var original_files:Dictionary = entry.files_to_copy.duplicate(true)
	entry.export_dir_path = root.path_join("invalid-output")
	optimization.set_parse_settings({"optimizer": {"enabled": true, "unknown": true}})
	entry.file_parser.pre_export()
	Fixture._check("invalid config invalidates export", entry.export_valid, false)
	Fixture._check("invalid config clears prepared replacements", optimization.replacements.is_empty(), true)
	Fixture._check("invalid config writes no package", DirAccess.dir_exists_absolute(entry.export_dir_path), false)
	var bad_path := root.path_join("invalid_struct.gd")
	var file := FileAccess.open(bad_path, FileAccess.WRITE)
	file.store_string("extends RefCounted\n#! struct\nclass Bad:\n\tvar value:int\n\tfunc unsupported() -> int:\n\t\treturn value\n")
	file.close()
	entry.files_to_copy = {bad_path: {}}
	entry.export_valid = true
	optimization.set_parse_settings({})
	entry.file_parser.pre_export()
	Fixture._check("invalid struct invalidates export", entry.export_valid, false)
	Fixture._check("invalid struct clears prepared replacements", optimization.replacements.is_empty(), true)
	Fixture._check("invalid struct writes no package", DirAccess.dir_exists_absolute(entry.export_dir_path), false)
	entry.export_valid = true
	optimization.set_parse_settings({"optimizer": {"enabled": false}})
	entry.file_parser.pre_export()
	Fixture._check("disabled optimizer bypasses invalid struct", entry.export_valid, true)
	Fixture._check("disabled optimizer clears statistics", optimization.stats.is_empty(), true)
	entry.files_to_copy = original_files
