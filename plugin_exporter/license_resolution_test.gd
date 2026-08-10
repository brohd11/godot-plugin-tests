@tool
extends EditorScript

## Tests for ExportObj.resolve_license_owners — the closest-ancestor matching behind
## gather_licenses. Synthetic paths only, nothing is read from disk: is_file_in_directory just
## globalizes and compares prefixes, so res:// paths that do not exist resolve fine.
##
##     load("res://tests/plugin_exporter/license_resolution_test.gd").run_tests()

const ExportObj = preload("res://addons/plugin_exporter/src/class/utils_local.gd").ExportObj

const LIB = "res://addons/addon_lib/brohd"
const CONFIG = "res://addons/addon_lib/brohd/dock_manager/config"
const PLUGIN = "res://addons/my_plugin"

const LIB_LICENSE = LIB + "/LICENSE"
const CONFIG_LICENSE = CONFIG + "/LICENSE"
const PLUGIN_LICENSE = PLUGIN + "/LICENSE"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_closest_ancestor()
	_test_domain_not_consumed()
	_test_order_independent()
	_test_unmatched()

	var output:Array[String] = []
	output.append("license_resolution: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


## The nested license owns its subtree, the outer one owns the rest — both end up used.
static func _test_closest_ancestor() -> void:
	var map = {
		LIB: LIB_LICENSE,
		CONFIG: CONFIG_LICENSE,
	}
	_check("nested file takes the deeper license",
		_owners(map, [CONFIG + "/settings.gd"]), [CONFIG_LICENSE])
	_check("sibling file takes the outer license",
		_owners(map, [LIB + "/alib_runtime/utils/u_file.gd"]), [LIB_LICENSE])
	_check("both licenses gathered when both subtrees are copied",
		_owners(map, [LIB + "/singleton/base.gd", CONFIG + "/settings.gd"]),
		[LIB_LICENSE, CONFIG_LICENSE])


## Matching used to erase a domain once it had claimed a file, which both skipped entries in the
## array it was iterating and let the second file of a pair fall through to an unrelated license.
static func _test_domain_not_consumed() -> void:
	var map = {
		LIB: LIB_LICENSE,
		PLUGIN: PLUGIN_LICENSE,
	}
	_check("a domain claims every file it contains",
		_owners(map, [LIB + "/a.gd", LIB + "/b.gd", LIB + "/c.gd"]), [LIB_LICENSE])
	_check("later domains stay reachable",
		_owners(map, [LIB + "/a.gd", LIB + "/b.gd", PLUGIN + "/plugin.gd"]),
		[LIB_LICENSE, PLUGIN_LICENSE])


## Domains arrive in filesystem scan order, which put ancestors first — the result must not
## depend on it.
static func _test_order_independent() -> void:
	var shallow_first = {LIB: LIB_LICENSE, CONFIG: CONFIG_LICENSE}
	var deep_first = {CONFIG: CONFIG_LICENSE, LIB: LIB_LICENSE}
	var files = [CONFIG + "/settings.gd"]
	_check("insertion order does not change the owner",
		_owners(shallow_first, files), _owners(deep_first, files))


## gather_licenses holds res:// out of the map, so anything it alone would have covered is
## simply unlicensed unless include_project_license adds it back.
static func _test_unmatched() -> void:
	var map = {LIB: LIB_LICENSE}
	_check("file outside every domain matches nothing",
		_owners(map, ["res://namespace/singletons.gd"]), [])
	_check("the license's own dir does not contain itself",
		_owners(map, [LIB + "/"]), [])


## Sorted so a set comparison reads as an array literal.
static func _owners(map:Dictionary, files:Array) -> Array:
	var keys = ExportObj.resolve_license_owners(map, files).keys()
	keys.sort()
	return keys


static func _check(label:String, actual, expected) -> void:
	if actual == expected:
		_passed += 1
	else:
		_failures.append("%s\n          expected: %s\n          actual:   %s" % [label, expected, actual])
