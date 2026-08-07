@tool
extends EditorScript

## Tests for the access-path reduction planner — what `reduce_access_paths` decides a dotted
## expression should become before anything is rewritten.
##
## Fixtures are written to user:// and scanned with the real collector, so `consumed` comes from
## an actual walk rather than a hand-built edge. The shapes are the ones that exist in this
## project: full chains through generated namespace hubs, chains ending in an inner class, and
## chains whose head is already the deepest file they name.
##
##     load("res://tests/plugin_exporter/access_reduction_test.gd").run_tests()

const UResource = preload("uid://72uu8yngsoht") #! resolve ALibRuntime.Utils.UResource
const Dependencies = UResource.Dependencies
const DepEdge = Dependencies.DepEdge

const DIR = "user://pe_access_reduction_tests/"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_reset_dir()

	_test_full_chain()
	_test_inner_class_tail()
	_test_head_is_deepest_file()
	_test_local_const_head()
	_test_off_by_default()

	_reset_dir()

	var output:Array[String] = []
	output.append("access_reduction: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


## The shape the whole feature exists for: a two-level hub chain collapsing to the leaf file.
static func _test_full_chain() -> void:
	var leaf = _w("r_leaf.gd", "extends RefCounted\n")
	var mid = _w("r_mid.gd", _hub('const Leaf = preload("%s")\n' % leaf))
	var top = _w("r_top.gd", _hub('const Mid = preload("%s")\n' % mid))
	var user = _w("r_user.gd", "extends RefCounted\nvar v = Hub.Mid.Leaf\n")

	var plan = _plan(user, {"Hub": top})
	_check("full: one reduction", plan.size(), 1)
	var entry = plan.get("Hub.Mid.Leaf", {})
	_check("full: binds the last segment", entry.get("name", ""), "Leaf")
	_check("full: binds to the leaf file", entry.get("path", ""), leaf)
	_check("full: no tail", entry.get("tail", null), [])


## The walk stops at the last real file; the inner class rides along on the rewritten expression.
static func _test_inner_class_tail() -> void:
	var real = _w("r_real.gd", "extends RefCounted\nclass Inner:\n\tpass\n")
	var hub = _w("r_hub2.gd", _hub('const Real = preload("%s")\n' % real))
	var user = _w("r_user2.gd", "extends RefCounted\nvar v = Hub.Real.Inner\n")

	var plan = _plan(user, {"Hub": hub})
	var entry = plan.get("Hub.Real.Inner", {})
	_check("inner: binds the file, not the inner class", entry.get("name", ""), "Real")
	_check("inner: binds to the real file", entry.get("path", ""), real)
	_check("inner: keeps the tail", entry.get("tail", null), ["Inner"])


## `FileSystemSingleton.FileData.FAVORITES_META` in miniature: the head IS the deepest file, so
## reducing would rewrite the expression to itself and would wrongly mark the class unused.
static func _test_head_is_deepest_file() -> void:
	var head = _w("r_head.gd", "extends RefCounted\nclass Data:\n\tconst FLAG = \"x\"\n")
	var user = _w("r_user3.gd", "extends RefCounted\nvar v = Head.Data.FLAG\n")

	var plan = _plan(user, {"Head": head})
	_check("head-deepest: no reduction planned", plan.is_empty(), true)


## The collector walks a local `const X = preload()` head just as happily, but the exporter must
## not reduce it: a plugin's own aggregator ("UtilsRemote.URegex") is deliberate indirection that
## `#! remote` already handles, and only a global-class head can be a namespace hub.
static func _test_local_const_head() -> void:
	var leaf = _w("r_leaf4.gd", "extends RefCounted\n")
	var mid = _w("r_mid4.gd", 'const Leaf = preload("%s")\n' % leaf)
	var user = _w("r_user4.gd", 'const M = preload("%s")\nvar v = M.Leaf\n' % mid)

	_check("local head: not planned", _plan(user, {}).has("M.Leaf"), false)

	# the resolution itself still happened - it is the policy that declines it, not the walk
	var resolved = false
	for edge in _scan(user, {}):
		if edge.meta.get(DepEdge.META_RESOLVED_FROM, "") == "M.Leaf":
			resolved = true
			_check("local head: flagged as not from the class map",
				edge.meta.get(DepEdge.META_HEAD_FROM_CLASS_MAP, true), false)
	_check("local head: collector still resolved it", resolved, true)

	# the same chain with a global-class head IS planned
	var hub = _w("r_hub4.gd", _hub('const Leaf = preload("%s")\n' % leaf))
	var user2 = _w("r_user4b.gd", "extends RefCounted\nvar v = Hub.Leaf\n")
	var entry = _plan(user2, {"Hub": hub}).get("Hub.Leaf", {})
	_check("class head: binds the leaf", entry.get("name", ""), "Leaf")
	_check("class head: binds to the leaf file", entry.get("path", ""), leaf)


## With no class map the scanner does no access-path work, so nothing is planned - this is what
## makes the flag genuinely inert when it is off.
static func _test_off_by_default() -> void:
	var leaf = _w("r_leaf5.gd", "extends RefCounted\n")
	var hub = _w("r_hub5.gd", _hub('const Leaf = preload("%s")\n' % leaf))
	var user = _w("r_user5.gd", "extends RefCounted\nvar v = Hub.Leaf\n")

	var scanner = Dependencies.new()
	scanner.max_depth = 1
	scanner.include_missing = false
	scanner.use_project_classes = false
	scanner.resolve_access_paths = false
	scanner.roots = [user]
	var edges = scanner.get_graph().get_out_edges(user)

	var plan = {}
	for edge in edges:
		if edge.meta.has(DepEdge.META_RESOLVED_FROM):
			plan[edge.meta[DepEdge.META_RESOLVED_FROM]] = true
	_check("off: nothing resolved", plan.is_empty(), true)
	# and the hub itself is not reached either, since only class-map lookups would find it
	_check("off: leaf not reached", hub in scanner.get_graph().get_paths(), false)


# --- harness -----------------------------------------------------------------------------

## Mirrors build_dep_scanner() with a class map.
static func _scan(root:String, class_map:Dictionary) -> Array:
	var scanner = Dependencies.new()
	scanner.max_depth = 1
	scanner.include_missing = false
	scanner.use_project_classes = false
	scanner.class_map = class_map
	scanner.resolve_access_paths = true
	scanner.roots = [root]
	return scanner.get_graph().get_out_edges(root)


## Folds the edges the way parse_base.edges_to_reductions() does. Duplicated rather than
## imported: parse_base pulls utils_local and the whole export pipeline in behind it, which does
## not compile in a clean headless run. Keep the two in step.
static func _plan(root:String, class_map:Dictionary) -> Dictionary:
	var out = {}
	for edge in _scan(root, class_map):
		var expression:String = edge.meta.get(DepEdge.META_RESOLVED_FROM, "")
		if expression == "" or edge.to == "" or out.has(expression):
			continue
		if not edge.meta.get(DepEdge.META_HEAD_FROM_CLASS_MAP, false):
			continue
		var consumed:int = edge.meta.get(DepEdge.META_CONSUMED, 0)
		if consumed < 2:
			continue
		var parts = expression.split(".", false)
		if consumed > parts.size():
			continue
		out[expression] = {
			"name": parts[consumed - 1],
			"path": edge.to,
			"tail": Array(parts.slice(consumed)),
		}
	return out


## The header the Namespace addon writes; the collector flags these files as hubs.
static func _hub(body:String) -> String:
	return "# This file is auto-generated. Do not edit.\n\n" + body


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
