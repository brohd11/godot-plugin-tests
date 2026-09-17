@tool
extends EditorScript

## Tests for the build_require writer: reading the specs a config already lists in every shape this
## project uses, and splicing a new list back in without touching anything else. Pure text, so no
## crawl, no git and no editor.
##
##     load("res://tests/plugin_exporter/require_update_test.gd").run_tests()

const RequireUpdate = preload("res://addons/plugin_exporter/src/class/release/require_update.gd")

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_read_yaml()
	_test_read_json()
	_test_rewrite_yaml_present()
	_test_rewrite_yaml_absent()
	_test_rewrite_json_absent()
	_test_rewrite_json_present()
	_test_empty()
	_test_untouched()
	_test_repin()

	var output:Array[String] = []
	output.append("require_update: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _test_read_yaml() -> void:
	_check("block list", RequireUpdate.read_build_require(
		'export_root: "x"\nbuild_require:\n  - "a/b@v1"\n  - c/d@v2\nexports: []\n', "yml"),
		["a/b@v1", "c/d@v2"])
	_check("@require dropped", RequireUpdate.read_build_require("build_require: @require\n", "yml"), [])
	_check("scalar spec", RequireUpdate.read_build_require('build_require: "a/b@v1"\n', "yml"), ["a/b@v1"])
	_check("flow seq", RequireUpdate.read_build_require('build_require: ["a/b@v1", "c/d@v2"]\n', "yml"),
		["a/b@v1", "c/d@v2"])
	_check("empty flow seq", RequireUpdate.read_build_require("build_require: []\n", "yml"), [])
	_check("multi-line flow seq", RequireUpdate.read_build_require(
		'build_require: ["a/b@v1",\n  "c/d@v2"]\nexports: []\n', "yml"), ["a/b@v1", "c/d@v2"])
	_check("comment inside a block", RequireUpdate.read_build_require(
		"build_require:\n  # note\n  - a/b@v1\nexports: []\n", "yml"), ["a/b@v1"])
	_check("missing key", RequireUpdate.read_build_require('export_root: "x"\n', "yml"), [])
	# An indented build_require belongs to some other mapping, and a similar key is not this one.
	_check("nested key ignored", RequireUpdate.read_build_require(
		"options:\n  build_require:\n    - a/b@v1\n", "yml"), [])
	_check("longer key ignored", RequireUpdate.read_build_require("build_requirements: [a/b@v1]\n", "yml"), [])


static func _test_read_json() -> void:
	_check("json array", RequireUpdate.read_build_require(
		'{\n\t"build_require": [\n\t\t"a/b@v1",\n\t\t"c/d@v2"\n\t],\n\t"export_root": "x"\n}', "json"),
		["a/b@v1", "c/d@v2"])
	_check("json one line", RequireUpdate.read_build_require('{"build_require": ["a/b@v1"]}', "json"), ["a/b@v1"])
	_check("json scalar @require", RequireUpdate.read_build_require('{"build_require": "@require"}', "json"), [])
	_check("json missing key", RequireUpdate.read_build_require('{"export_root": "x"}', "json"), [])


static func _test_rewrite_yaml_present() -> void:
	var text = 'export_root: "x"\nbuild_require: @require\nexports:\n  - source: "y"\n'
	_check("yaml: @require replaced", RequireUpdate.rewrite(text, "yml", ["a/b@v1", "c/d@v2"]),
		'export_root: "x"\nbuild_require:\n  - "a/b@v1"\n  - "c/d@v2"\nexports:\n  - source: "y"\n')

	var block = 'build_require:\n  - "a/b@v1"\n  - "old/x@v0.1"\ncompile_require: []\n'
	_check("yaml: block replaced in place", RequireUpdate.rewrite(block, "yml", ["a/b@v2"]),
		'build_require:\n  - "a/b@v2"\ncompile_require: []\n')

	_check("yaml: flow seq replaced", RequireUpdate.rewrite('build_require: ["a/b@v1"]\nexports: []\n', "yml", ["a/b@v1"]),
		'build_require:\n  - "a/b@v1"\nexports: []\n')


static func _test_rewrite_yaml_absent() -> void:
	var text = 'export_root: "x"\n# keep me\nexports:\n  - source: "y"\noptions: {}\n'
	_check("yaml: inserted above exports", RequireUpdate.rewrite(text, "yml", ["a/b@v1"]),
		'export_root: "x"\n# keep me\nbuild_require:\n  - "a/b@v1"\nexports:\n  - source: "y"\noptions: {}\n')
	_check("yaml: appended before the trailing newline", RequireUpdate.rewrite('export_root: "x"\n', "yml", ["a/b@v1"]),
		'export_root: "x"\nbuild_require:\n  - "a/b@v1"\n')


static func _test_rewrite_json_absent() -> void:
	var text = '{\n\t"export_root": "x",\n\t"exports": [\n\t\t{}\n\t]\n}\n'
	_check("json: inserted as the first key", RequireUpdate.rewrite(text, "json", ["a/b@v1", "c/d@v2"]),
		'{\n\t"build_require": [\n\t\t"a/b@v1",\n\t\t"c/d@v2"\n\t],\n\t"export_root": "x",\n\t"exports": [\n\t\t{}\n\t]\n}\n')
	# Trailing commas and spaces: this project's json configs carry both, and neither may move.
	var spaced = '{\n    "export_root": "x",\n    "options": {\n        "overwrite": true,\n    }\n}\n'
	_check("json: space indent matched", RequireUpdate.rewrite(spaced, "json", ["a/b@v1"]),
		'{\n    "build_require": [\n        "a/b@v1"\n    ],\n    "export_root": "x",\n    "options": {\n        "overwrite": true,\n    }\n}\n')


static func _test_rewrite_json_present() -> void:
	var text = '{\n\t"build_require": [\n\t\t"a/b@v1"\n\t],\n\t"export_root": "x"\n}\n'
	_check("json: value replaced", RequireUpdate.rewrite(text, "json", ["a/b@v2", "c/d@v1"]),
		'{\n\t"build_require": [\n\t\t"a/b@v2",\n\t\t"c/d@v1"\n\t],\n\t"export_root": "x"\n}\n')
	_check("json: scalar value replaced", RequireUpdate.rewrite('{\n\t"build_require": "@require",\n\t"export_root": "x"\n}\n', "json", ["a/b@v1"]),
		'{\n\t"build_require": [\n\t\t"a/b@v1"\n\t],\n\t"export_root": "x"\n}\n')


static func _test_empty() -> void:
	_check("yaml: empty list", RequireUpdate.rewrite("build_require:\n  - a/b@v1\nexports: []\n", "yml", []),
		"build_require: []\nexports: []\n")
	_check("json: empty list", RequireUpdate.rewrite('{\n\t"build_require": ["a/b@v1"],\n\t"export_root": "x"\n}\n', "json", []),
		'{\n\t"build_require": [],\n\t"export_root": "x"\n}\n')


## An unchanged list has to come back byte-identical, or `update` would churn every config it reads.
static func _test_untouched() -> void:
	var yml = 'export_root: "x"\nbuild_require:\n  - "a/b@v1"\n# a comment\nexports: []\n'
	_check("yaml: idempotent", RequireUpdate.rewrite(yml, "yml", RequireUpdate.read_build_require(yml, "yml")), yml)
	var json = '{\n\t"build_require": [\n\t\t"a/b@v1"\n\t],\n\t"export_root": "x"\n}\n'
	_check("json: idempotent", RequireUpdate.rewrite(json, "json", RequireUpdate.read_build_require(json, "json")), json)


static func _test_repin() -> void:
	_check("repin plain", RequireUpdate.repin("a/b@v1", "v2"), "a/b@v2")
	_check("repin untagged", RequireUpdate.repin("a/b", "v2"), "a/b@v2")
	_check("repin keeps host and source", RequireUpdate.repin("gitlab.com/a/b/source@v1", "v2"),
		"gitlab.com/a/b/source@v2")
	_check("short_id drops only github.com", RequireUpdate.short_id("github.com/a/b"), "a/b")
	_check("short_id keeps other hosts", RequireUpdate.short_id("gitlab.com/a/b"), "gitlab.com/a/b")


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])
