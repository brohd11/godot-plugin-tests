@tool
extends EditorScript

## Tests for the export-ignore folder helper: both spellings, `_export_ignore` winning when a plugin
## has both, and the always-excluded path check.
##
##     load("res://tests/plugin_exporter/export_ignore_test.gd").run_tests()

const ExportIgnore = preload("res://addons/plugin_exporter/src/class/export/export_ignore.gd")
const ReleaseRunner = preload("res://addons/plugin_exporter/src/class/release/release_runner.gd")

const DIR = "user://pe_export_ignore_tests"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	var root = ProjectSettings.globalize_path(DIR)
	ReleaseRunner.remove_dir(root)

	_test_names()
	_test_dirs(root)
	_test_candidates()
	_test_is_inside()

	ReleaseRunner.remove_dir(root)
	var output:Array[String] = []
	output.append("export_ignore: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _test_names() -> void:
	_check("new name", ExportIgnore.is_name("_export_ignore"), true)
	_check("old name", ExportIgnore.is_name("export_ignore"), true)
	_check("other folder", ExportIgnore.is_name("exports"), false)


static func _test_dirs(root:String) -> void:
	var neither = root.path_join("neither")
	DirAccess.make_dir_recursive_absolute(neither)
	_check("neither: dir_in empty", ExportIgnore.dir_in(neither), "")
	_check("neither: default is the new name", ExportIgnore.dir_or_default(neither), neither.path_join("_export_ignore"))

	var old = root.path_join("old")
	DirAccess.make_dir_recursive_absolute(old.path_join("export_ignore"))
	_check("old only: used", ExportIgnore.dir_in(old), old.path_join("export_ignore"))
	_check("old only: kept by default", ExportIgnore.dir_or_default(old), old.path_join("export_ignore"))

	var both = root.path_join("both")
	DirAccess.make_dir_recursive_absolute(both.path_join("export_ignore"))
	DirAccess.make_dir_recursive_absolute(both.path_join("_export_ignore"))
	_check("both: new name wins", ExportIgnore.dir_in(both), both.path_join("_export_ignore"))


static func _test_candidates() -> void:
	_check("candidates: preferred name first", ExportIgnore.candidates("res://addons/p", ["a.yml", "b.json"]), [
		"res://addons/p/_export_ignore/a.yml", "res://addons/p/_export_ignore/b.json",
		"res://addons/p/export_ignore/a.yml", "res://addons/p/export_ignore/b.json"])
	_check("candidates: relative to a package root", ExportIgnore.candidates("", ["c.yml"]),
		["_export_ignore/c.yml", "export_ignore/c.yml"])


static func _test_is_inside() -> void:
	_check("inside new", ExportIgnore.is_inside("res://addons/p/_export_ignore/doc/a.md", "res://addons/p/"), true)
	_check("inside old", ExportIgnore.is_inside("res://addons/p/export_ignore/pre_post_export.gd", "res://addons/p"), true)
	_check("nested deeper is not the plugin's", ExportIgnore.is_inside("res://addons/p/src/export_ignore/a.gd", "res://addons/p/"), false)
	_check("similar file name", ExportIgnore.is_inside("res://addons/p/export_ignore_notes.md", "res://addons/p/"), false)
	_check("other plugin", ExportIgnore.is_inside("res://addons/q/_export_ignore/a.gd", "res://addons/p/"), false)


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])
