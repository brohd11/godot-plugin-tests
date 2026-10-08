@tool
extends EditorScript
## package_init's version.cfg template and the unpackaged-dir completion scan.

const Discovery = preload("res://addons/plugin_exporter/src/class/export/package_discovery.gd")
const PluginInit = preload("res://addons/plugin_exporter/src/class/export/plugin_init.gd")
const Runner = preload("res://addons/plugin_exporter/src/class/release/release_runner.gd")
const ROOT = "user://pe_package_init_tests"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	_test_version_cfg()
	_test_unpackaged()
	var output:Array[String] = ["package_init: %d passed, %d failed" % [_passed, _failures.size()]]
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


static func _test_version_cfg() -> void:
	var cfg = ConfigFile.new()
	_check("cfg parses", cfg.parse(PluginInit.version_cfg_text("res://addons/_lib/my_pkg/")), OK)
	_check("name is folder", cfg.get_value("plugin", "name"), "my_pkg")
	_check("path drops res://", cfg.get_value("plugin", "path"), "addons/_lib/my_pkg")
	_check("version", cfg.get_value("plugin", "version"), "0.1.0")
	_check("url", cfg.get_value("plugin", "url"), "")
	_check("require", cfg.get_value("plugin", "require"), [])
	_check("namespace path", cfg.get_value("namespace", "path"), "")


static func _test_unpackaged() -> void:
	Runner.remove_dir(ProjectSettings.globalize_path(ROOT))
	_mkdir("bare/deep/deeper")
	_mkdir("group/lib/src")
	_mkdir("group/new_lib")
	_mkdir(".hidden/x")
	_mkdir("_export_ignore/x")
	_write("plugin/plugin.cfg")
	_mkdir("plugin/src")
	_write("group/lib/version.cfg")
	var dir = DirAccess.open(ROOT)
	_check("symlink fixture", dir.create_link(ProjectSettings.globalize_path(ROOT), "loop"), OK)
	_check("unpackaged default depth", Discovery.discover_unpackaged(ROOT).keys(),
		["bare", "bare/deep", "group", "group/new_lib"])
	_check("depth 1", Discovery.discover_unpackaged(ROOT, 1).keys(), ["bare", "group"])
	_write("group/new_lib/version.cfg")
	_check("initialized drops off", Discovery.discover_unpackaged(ROOT).keys(), ["bare", "bare/deep", "group"])
	_check("missing root", Discovery.discover_unpackaged(ROOT.path_join("missing")), {})
	DirAccess.remove_absolute(ROOT.path_join("loop"))
	Runner.remove_dir(ProjectSettings.globalize_path(ROOT))


static func _mkdir(relative:String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(relative))


static func _write(relative:String) -> void:
	var path = ROOT.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("")


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
	else:
		_failures.append("%s (expected %s, got %s)" % [label, expected, got])
