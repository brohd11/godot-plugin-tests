@tool
extends EditorScript

## Tests for plugin_exporter's `#! dependency` tag handler — the one handler the exporter
## registers on UResource.Dependencies. The collector itself ships no handlers; the mechanism
## it provides is covered by tests/dependencies.
##
## Fixtures are written to user:// for the same reason the collector suite does it: the tag
## lines are more readable sitting next to the assertion that reads them.
##
##     load("res://tests/plugin_exporter/dependency_tags_test.gd").run_tests()

const UResource = preload("uid://72uu8yngsoht") #! resolve ALibRuntime.Utils.UResource
const Dependencies = UResource.Dependencies
const Kind = Dependencies.Kind
const DependencyTags = preload("res://addons/plugin_exporter/src/class/export/dependency_tags.gd")
const DIR_KEY = DependencyTags.DIR_KEY

const DIR = "user://pe_dependency_tag_tests/"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_reset_dir()

	_test_handler_values()
	_test_handler_declines()
	_test_scan_end_to_end()

	_reset_dir()

	var output:Array[String] = []
	output.append("dependency_tags: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


## The directory is whatever follows the tag. A path may sit between the two, in which case it
## is dropped — it is already in `raws`, and what follows is still the directory.
static func _test_handler_values() -> void:
	_check("value: bare word", _dir("current", ["res://a.gd"]), "current")
	_check("value: after a quoted path", _dir('"res://a.png" assets', ["res://a.png"]), "assets")
	_check("value: after a single-quoted path", _dir("'res://a.png' assets", ["res://a.png"]), "assets")
	_check("value: nothing after the path", _dir('"res://a.png"', ["res://a.png"]), "")
	_check("value: absent", _dir("", ["res://a.gd"]), "")
	_check("value: path in a subdir", _dir("res://addons/x/deps", ["res://a.gd"]), "res://addons/x/deps")


## No path on the line means nothing to mark, so no edge is emitted at all.
static func _test_handler_declines() -> void:
	var handler = DependencyTags.dependency_dir()
	_check("declines: no path literal", handler.call(_ctx("current", [])), null)
	_check("declines: no path, no value", handler.call(_ctx("", [])), null)


## The tag reaching the graph is what the export crawl actually consumes: parse_base folds
## `edge.meta[dependency_dir]` straight into the legacy dependency dict.
static func _test_scan_end_to_end() -> void:
	var asset = _w("dep_asset.gd", "extends RefCounted\n")
	var src = _w("dep_src.gd", "\n".join([
		# the shape the old elif chain swallowed: the preload branch won and dropped the dir
		'const A = preload("%s") #! dependency current' % asset,
		'#! dependency "%s" assets' % asset,
		# prose about the tag must not fire it — the tag has to open the comment
		'## tag it `#! dependency "res://nope.gd"` to pull a file in',
	]) + "\n")

	var d = Dependencies.open(src)
	d.use_project_classes = false
	d.add_tag_handler(DependencyTags.TAG, DependencyTags.dependency_dir())
	var graph = d.get_graph()

	var tag_edges = graph.get_edges_of_kind(Kind.TAG)
	_check("scan: two tag edges", tag_edges.size(), 2)
	_check("scan: dir from bare value", tag_edges[0].meta.get(DIR_KEY, ""), "current")
	_check("scan: dir after quoted path", tag_edges[1].meta.get(DIR_KEY, ""), "assets")
	_check("scan: tag name", tag_edges[0].tag, DependencyTags.TAG)
	_check("scan: preload on the tagged line still found", graph.get_edges_of_kind(Kind.PRELOAD).size(), 1)
	_check("scan: prose does not fire", graph.has("res://nope.gd"), false)


# --- harness -----------------------------------------------------------------------------

static func _dir(value:String, raws:Array):
	var result = DependencyTags.dependency_dir().call(_ctx(value, raws))
	return "" if result == null else result.get(DIR_KEY, "")


static func _ctx(value:String, raws:Array) -> Dictionary:
	return {
		"file_path": DIR + "ctx.gd",
		"line": "#! dependency " + value,
		"line_no": 1,
		"tag": DependencyTags.TAG,
		"value": value,
		"raws": raws,
	}


static func _w(rel_path:String, text:String) -> String:
	var path = DIR + rel_path
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("could not write fixture: " + path)
		return path
	file.store_string(text)
	file.close()
	return path


static func _reset_dir() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		_rm_recursive(DIR)
	DirAccess.make_dir_recursive_absolute(DIR)


static func _rm_recursive(dir:String) -> void:
	var da = DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	for d in da.get_directories():
		_rm_recursive(dir.path_join(d) + "/")
	DirAccess.remove_absolute(dir)


static func _check(label:String, actual, expected) -> void:
	if actual == expected:
		_passed += 1
	else:
		_failures.append("%s\n          expected: %s\n          actual:   %s" % [label, expected, actual])
