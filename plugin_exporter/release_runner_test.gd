@tool
extends EditorScript
## The runner passes the selected config directly, even with an older name-only toolchain.

const Runner = preload("res://addons/plugin_exporter/src/class/release/release_runner.gd")
const ROOT = "user://pe_release_runner_tests"
const CONFIG = "res://lib/pkg/_export_ignore/export.yml"

const FILE_UTILS = '''extends RefCounted
static func get_export_config_path(_target):
	assert(false, "runner must not resolve targets through the pinned toolchain")
	return ""
static func get_export_data(_path):
	return {"export_root": "res://output", "plugin_folder": "build", "exports": [{}]}
static func get_full_export_path(root, folder, _config):
	return ProjectSettings.globalize_path(root.path_join(folder))
static func get_export_folder(_entry, _config):
	return "lib/pkg/"
static func get_export_name(_entry, _folder, _config):
	return "pkg/"
'''


static func run_tests() -> Dictionary:
	var root = ProjectSettings.globalize_path(ROOT)
	Runner.remove_dir(root)
	_write(root.path_join("project.godot"), Runner.project_godot("Release Runner Test", [
		"res://addons/%s/plugin.cfg" % Runner.EXPORT_AUTORUN_DIR]))
	_write(root.path_join(CONFIG.trim_prefix("res://")), "exports: []\n")
	var scripts = root.path_join("addons/plugin_exporter/src/class/export")
	_write(scripts.path_join("plugin_exporter_file_utils.gd"), FILE_UTILS)
	_write(scripts.path_join("plugin_exporter_static.gd"),
		'extends RefCounted\nstatic func export_plugin(config):\n\treturn config == "%s" and FileAccess.file_exists(config)\n' % CONFIG)
	Runner.write_export_autorun(root)
	var run = Runner.run_export(root, CONFIG)
	var failures:Array[String] = []
	if run.exit != 0 or not run.result.get("ok", false) or not Runner.script_errors(run.output).is_empty():
		failures.append("selected config failed: " + run.output)
	elif run.result.exports[0].install_path != "res://lib/pkg":
		failures.append("runner lost the non-addon install path")
	Runner.remove_dir(root)
	var output:Array[String] = ["release_runner: %d failed" % failures.size()]
	output.append_array(failures)
	return {"result": failures.size(), "output": output}


static func _write(path:String, content:String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
