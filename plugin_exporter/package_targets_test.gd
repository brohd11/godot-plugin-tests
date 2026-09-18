@tool
extends EditorScript
## Config lookup and version tokens must retain package identity outside addons/.

const Files = preload("res://addons/plugin_exporter/src/class/export/plugin_exporter_file_utils.gd")
const Runner = preload("res://addons/plugin_exporter/src/class/release/release_runner.gd")
const Workspace = preload("res://addons/plugin_exporter/src/class/release/release_workspace.gd")
const ROOT = "res://tests/plugin_exporter/fixtures/_package_targets"

static var _failures:Array[String] = []
static var _passed:int = 0


class Fetcher:
	var root:String
	var last_error = ""
	func stage(_entry:Dictionary) -> String:
		return root.path_join("staged")


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	Runner.remove_dir(ProjectSettings.globalize_path(ROOT))
	_write(ROOT.path_join(".gdignore"), "")
	var target = ROOT.path_join("plugin_exporter")
	var config = target.path_join("_export_ignore/export.yml")
	_write(target.path_join("plugin.cfg"), '[plugin]\nversion="9.9.9"\n')
	_write(config, 'export_root: "unused"\n')
	for input in [target, ProjectSettings.globalize_path(target), "../" + target.trim_prefix("res://")]:
		_check("config identity: " + input, Files.get_export_config_path(input), config)
		_check("version identity: " + input, Files.get_version(input, config), "9.9.9")
	_check("path token", Files.replace_version("pkg{{version=%s}}" % target, config), "pkg-9.9.9/")
	var relative = "../" + target.trim_prefix("res://")
	_check("relative token", Files.replace_version("pkg{{version=%s}}/next" % relative, config), "pkg-9.9.9/next/")
	_check("multiple tokens", Files.replace_version("a{{version=%s}}/b{{version=%s}}" % [target, target], config), "a-9.9.9/b-9.9.9/")
	_write(target.path_join("version.cfg"), '[plugin]\nversion="8.8.8"\n')
	_check("plugin cfg preferred", Files.get_version(target, config), "9.9.9")
	DirAccess.remove_absolute(target.path_join("plugin.cfg"))
	_check("version cfg supported", Files.get_version(target, config), "8.8.8")
	_check("legacy fallback", Files.replace_version("missing{{version}}", config), "missing-8.8.8/")
	_test_workspace()
	Runner.remove_dir(ProjectSettings.globalize_path(ROOT))
	var output:Array[String] = ["package_targets: %d passed, %d failed" % [_passed, _failures.size()]]
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


static func _test_workspace() -> void:
	var fetcher = Fetcher.new()
	fetcher.root = ProjectSettings.globalize_path(ROOT.path_join("cache"))
	var source = fetcher.root.path_join("staged")
	_write(source.path_join("version.cfg"), '[plugin]\nversion="1.0.0"\n')
	_write(source.path_join("_export_ignore/export.yml"), 'export_root: "old"\nexports: []\n')
	var toolchain = fetcher.root.path_join("toolchain")
	_write(toolchain.path_join("plugin.cfg"), '[plugin]\nversion="1.0.0"\n')
	var lock = {"target": {"path": "res://lib/pkg", "repo_id": "example/pkg", "tag": "v1.0.0"}, "deps": []}
	var workspace = Workspace.new(fetcher)
	var output = fetcher.root.path_join("output")
	var ws = workspace.build(lock, "res://lib/pkg", toolchain, output, "")
	_check("workspace builds: " + str(workspace.errors), ws != "", true)
	_check("filesystem alias", workspace.workspace_dir(ProjectSettings.globalize_path("res://lib/pkg"), lock), ws)
	_check("workspace contained", ws.get_base_dir(), fetcher.root.path_join("workspaces"))
	_check("non-addon source installed", FileAccess.file_exists(ws.path_join("lib/pkg/version.cfg")), true)
	var config = ws.path_join("lib/pkg/_export_ignore/export.yml")
	_check("config retargeted", FileAccess.get_file_as_string(config), 'export_root: "%s"\nexports: []\n' % output)
	var old_lock = lock.duplicate(true)
	old_lock.target.tag = "v0.9.0"
	var old = workspace.workspace_dir("res://lib/pkg", old_lock)
	_write(old.path_join("sentinel"), "")
	var other = workspace.workspace_dir("res://other/pkg", old_lock)
	_write(other.path_join("sentinel"), "")
	_check("workspace reused", workspace.build(lock, "res://lib/pkg", toolchain, output, ""), ws)
	_check("old target workspace pruned", DirAccess.dir_exists_absolute(old), false)
	_check("same basename preserved", FileAccess.file_exists(other.path_join("sentinel")), true)


static func _write(path:String, content:String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
	else:
		_failures.append("%s (expected %s, got %s)" % [label, expected, got])
