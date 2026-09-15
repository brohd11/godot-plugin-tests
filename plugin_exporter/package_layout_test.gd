@tool
extends EditorScript

## Tests for release export package placement - the gdaddon resolveInstall port. Layouts are
## plain file lists with cfg values in a dictionary, modelled on real packages: Godot-YAML-Parser's
## tag source and its release zip, and the nested addon_lib repos in this project.
##
##     load("res://tests/plugin_exporter/package_layout_test.gd").run_tests()

const PackageLayout = preload("res://addons/plugin_exporter/src/class/release/package_layout.gd")
const DepResolver = preload("res://addons/plugin_exporter/src/class/release/dep_resolver.gd")

const YAML_ID = "github.com/brohd11/godot-yaml-parser"
const YAML_URL = "https://github.com/brohd11/Godot-YAML-Parser.git"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_root_cfg()
	_test_full_project()
	_test_release_zip()
	_test_namespace_descent()
	_test_bundles()
	_test_junk()

	var output:Array[String] = []
	output.append("package_layout: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


## Submodule style: the repo is the addon, so only its own cfg can place it.
static func _test_root_cfg() -> void:
	var files = ["plugin.cfg", "plugin.gd", "src/a.gd"]
	_check("root: path=", _locate(files, {"": {"path": "addons/addon_lib/brohd"}}),
		{"src": "", "dest": "res://addons/addon_lib/brohd"})
	_check("root: dir= wins over path=", _locate(files, {"": {"dir": "addons/x", "path": "addons/y"}}).dest,
		"res://addons/x")
	_check("root: res:// prefix tolerated", _locate(files, {"": {"path": "res://addons/z/"}}).dest, "res://addons/z")
	_check("root: no path is an error", _locate(files, {"": {}}).has("error"), true)
	var no_path = func(_dir:String, _key:String) -> String: return ""
	_check("root: the target's known dir stands in for path=",
		PackageLayout.locate(files, YAML_ID, no_path, DepResolver.repo_id_from_url, "res://addons/t").dest, "res://addons/t")
	_check("root: escaping path ignored", _locate(files, {"": {"path": "../outside"}}).has("error"), true)


## Godot-YAML-Parser v2.1.0 source: a whole project with the addon under a namespace folder.
static func _test_full_project() -> void:
	var files = ["project.godot", "README.md", "tests/main_test.gd",
		"addons/addon_lib/yaml_parser/version.cfg", "addons/addon_lib/yaml_parser/yaml.gd"]
	_check("project: walked path", _locate(files, {"addons/addon_lib/yaml_parser": {"url": YAML_URL}}),
		{"src": "addons/addon_lib/yaml_parser", "dest": "res://addons/addon_lib/yaml_parser"})


## yaml-parser-2.1.0.zip: a wrapper, then a path relative to addons/, with macOS junk alongside.
static func _test_release_zip() -> void:
	var files = ["yaml-parser-2.1.0/", "__MACOSX/._yaml-parser-2.1.0", "yaml-parser-2.1.0/.DS_Store",
		"yaml-parser-2.1.0/addon_lib/yaml_parser/yaml.gd", "yaml-parser-2.1.0/addon_lib/yaml_parser/version.cfg",
		"__MACOSX/yaml-parser-2.1.0/addon_lib/yaml_parser/._version.cfg"]
	var cfgs = {"yaml-parser-2.1.0/addon_lib/yaml_parser": {"url": YAML_URL}}
	_check("zip: wrapper stripped, path kept", _locate(files, cfgs),
		{"src": "yaml-parser-2.1.0/addon_lib/yaml_parser", "dest": "res://addons/addon_lib/yaml_parser"})

	var bare = ["addon_lib/yaml_parser/yaml.gd", "addon_lib/yaml_parser/version.cfg", "LICENSE"]
	_check("zip without wrapper", _locate(bare, {"addon_lib/yaml_parser": {}}).dest, "res://addons/addon_lib/yaml_parser")


## Namespace levels without a cfg are descended, however deep the nesting goes.
static func _test_namespace_descent() -> void:
	var files = ["project.godot", "addons/addon_lib/gdsh_lib/utils/version.cfg", "addons/addon_lib/gdsh_lib/utils/u.gd"]
	_check("deep namespace", _locate(files, {"addons/addon_lib/gdsh_lib/utils": {}}),
		{"src": "addons/addon_lib/gdsh_lib/utils", "dest": "res://addons/addon_lib/gdsh_lib/utils"})

	var nested = ["addons/outer/plugin.cfg", "addons/outer/inner/plugin.cfg", "addons/outer/a.gd"]
	_check("nested cfg rides along with its parent", _locate(nested, {"addons/outer": {}, "addons/outer/inner": {}}).src,
		"addons/outer")


## A project shipping several addons: only the one whose url= names the repo is taken.
static func _test_bundles() -> void:
	var files = ["project.godot", "addons/gut/plugin.cfg", "addons/yaml/plugin.cfg", "addons/yaml/y.gd"]
	_check("bundle: url= picks", _locate(files, {"addons/gut": {"url": "https://github.com/bitwes/Gut"},
		"addons/yaml": {"url": YAML_URL}}).dest, "res://addons/yaml")
	var ambiguous = _locate(files, {"addons/gut": {}, "addons/yaml": {}})
	_check("bundle: no url= match is an error", ambiguous.has("error") and "addons/gut" in ambiguous.error, true)
	_check("bundle: single cfg beside an asset folder", _locate(["addons/icons/a.svg", "addons/p/plugin.cfg"],
		{"addons/p": {}}).dest, "res://addons/p")
	_check("asset pack with no cfg", _locate(["addons/icons/a.svg", "README.md"], {}).dest, "res://addons/icons")


static func _test_junk() -> void:
	_check("junk: macOS", PackageLayout.is_junk("__MACOSX/x/._a.gd"), true)
	_check("junk: DS_Store", PackageLayout.is_junk("addons/x/.DS_Store"), true)
	_check("junk: real file", PackageLayout.is_junk("addons/x/a.gd"), false)
	_check("empty package", _locate(["__MACOSX/._x"], {}).has("error"), true)


static func _locate(files:Array, cfgs:Dictionary) -> Dictionary:
	var cfg_value = func(dir:String, key:String) -> String:
		return str(cfgs.get(dir, {}).get(key, ""))
	return PackageLayout.locate(files, YAML_ID, cfg_value, DepResolver.repo_id_from_url)


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])
