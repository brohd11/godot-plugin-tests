@tool
extends EditorScript
## Packages are discovered by metadata, then filtered by export config presence.

const Discovery = preload("res://addons/plugin_exporter/src/class/export/package_discovery.gd")
const ExportIgnore = preload("res://addons/plugin_exporter/src/class/export/export_ignore.gd")
const Runner = preload("res://addons/plugin_exporter/src/class/release/release_runner.gd")
const ROOT = "user://pe_package_discovery_tests"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	Discovery.clear_cache()
	Runner.remove_dir(ProjectSettings.globalize_path(ROOT))
	_write("top/plugin.cfg")
	_write("top/version.cfg")
	_write("top/_export_ignore/export.yml")
	_write("top/nested/version.cfg")
	_write("group/lib/version.cfg")
	_write("group/lib/export_ignore/plugin_export.json")
	_write("config_only/_export_ignore/export.yml")
	for ignored in [".hidden", "top/_export_ignore", "top/export_ignore"]:
		_write(ignored.path_join("copy/plugin.cfg"))
	var dir = DirAccess.open(ROOT)
	_check("symlink fixture", dir.create_link(ProjectSettings.globalize_path(ROOT), "loop"), OK)
	_check("all sorted and deduplicated", Discovery.discover(ROOT, Discovery.Filter.ALL).keys(),
		["group/lib", "top", "top/nested"])
	_check("configured", Discovery.discover(ROOT).keys(), ["group/lib", "top"])
	_check("unconfigured", Discovery.discover(ROOT, Discovery.Filter.NOT_VALID).keys(), ["top/nested"])
	_check("unknown filter", Discovery.discover(ROOT, 99), {})
	_check("missing directory", Discovery.discover(ROOT.path_join("missing")), {})
	_check("default config", ExportIgnore.config_path(ROOT.path_join("top/nested")),
		ROOT.path_join("top/nested/_export_ignore/export.yml"))
	_write("top/_export_ignore/plugin_export.yml")
	_write("top/export_ignore/export.yml")
	_check("new filename first", ExportIgnore.config_path(ROOT.path_join("top")), ROOT.path_join("top/_export_ignore/export.yml"))
	DirAccess.remove_absolute(ROOT.path_join("top/_export_ignore/export.yml"))
	_check("folder precedence first", ExportIgnore.config_path(ROOT.path_join("top")), ROOT.path_join("top/_export_ignore/plugin_export.yml"))
	_test_cache()
	DirAccess.remove_absolute(ROOT.path_join("loop"))
	Runner.remove_dir(ProjectSettings.globalize_path(ROOT))
	Discovery.clear_cache()
	var output:Array[String] = ["package_discovery: %d passed, %d failed" % [_passed, _failures.size()]]
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


static func _test_cache() -> void:
	_write("added/version.cfg")
	_write("top/nested/_export_ignore/export.yml")
	DirAccess.remove_absolute(ROOT.path_join("group/lib/export_ignore/plugin_export.json"))
	_check("package scan cached", Discovery.discover(ROOT, Discovery.Filter.ALL).keys(), ["group/lib", "top", "top/nested"])
	_check("config presence cached", Discovery.discover(ROOT).keys(), ["group/lib", "top"])
	_check("filters share snapshot", Discovery.discover(ROOT, Discovery.Filter.NOT_VALID).keys(), ["top/nested"])
	_check("root aliases share snapshot", Discovery.discover(ProjectSettings.globalize_path(ROOT) + "/").keys(), ["group/lib", "top"])
	var returned = Discovery.discover(ROOT)
	returned["top"]["modified"] = true
	returned.erase("group/lib")
	_check("caller changes isolated", Discovery.discover(ROOT), {"group/lib": {}, "top": {}})
	_write("missing/child/version.cfg")
	_write("missing/child/_export_ignore/export.yml")
	_check("empty scan cached", Discovery.discover(ROOT.path_join("missing")), {})
	_check("separate scan root", Discovery.discover(ROOT.path_join("top"), Discovery.Filter.ALL).keys(), ["nested"])
	Discovery.clear_cache()
	_check("package addition after clear", Discovery.discover(ROOT, Discovery.Filter.ALL).keys(), ["added", "group/lib", "missing/child", "top", "top/nested"])
	_check("config changes after clear", Discovery.discover(ROOT).keys(), ["missing/child", "top", "top/nested"])
	_check("unconfigured after clear", Discovery.discover(ROOT, Discovery.Filter.NOT_VALID).keys(), ["added", "group/lib"])
	_check("empty root refreshed", Discovery.discover(ROOT.path_join("missing")).keys(), ["child"])
	DirAccess.remove_absolute(ROOT.path_join("added/version.cfg"))
	Discovery.clear_cache()
	_check("package removal after clear", Discovery.discover(ROOT, Discovery.Filter.ALL).keys(), ["group/lib", "missing/child", "top", "top/nested"])


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
