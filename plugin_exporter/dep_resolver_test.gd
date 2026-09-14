@tool
extends EditorScript

## Tests for the release export's dependency resolver: gdaddon-compatible dep parsing, tag ordering,
## and MVS selection. Repos are a fake fetcher (url -> tag -> files), so no git or network.
##
##     load("res://tests/plugin_exporter/dep_resolver_test.gd").run_tests()

const DepResolver = preload("res://addons/plugin_exporter/src/class/release/dep_resolver.gd")

static var _failures:Array[String] = []
static var _passed:int = 0


class FakeFetcher:
	var repos:Dictionary = {} # url -> {tag: {path: text}}
	var last_error:String = ""

	func add(spec:String, tag:String, files:Dictionary) -> String:
		var url = "https://github.com/" + spec
		if not repos.has(url):
			repos[url] = {}
		repos[url][tag] = files
		return url

	func tag_sha(url:String, tag:String) -> String:
		if repos.has(url) and repos[url].has(tag):
			return ("%s@%s" % [url, tag]).sha1_text()
		return ""

	func read_file(url:String, tag:String, path:String):
		if not repos.has(url) or not repos[url].has(tag):
			return null
		return repos[url][tag].get(path)


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_parse_dep()
	_test_cfg_keys()
	_test_repo_id()
	_test_compare_tags()
	_test_mvs()
	_test_tag_v_toggle()
	_test_failures()
	_test_cycle()
	_test_local_override()

	var output:Array[String] = []
	output.append("dep_resolver: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _test_parse_dep() -> void:
	var d = DepResolver.parse_dep("Brohd11/Godot-Addon-Lib@v2.1.0")
	_check("short form host", d.host, "github.com")
	_check("short form id lowercased", d.repo_id, "github.com/brohd11/godot-addon-lib")
	_check("short form tag", d.tag, "v2.1.0")
	_check("short form url keeps case", d.repo_url, "https://github.com/Brohd11/Godot-Addon-Lib")

	var h = DepResolver.parse_dep("gitlab.com/o/r@1.0")
	_check("host form", [h.host, h.owner, h.repo, h.tag], ["gitlab.com", "o", "r", "1.0"])
	_check("tagless", DepResolver.parse_dep("o/r").tag, "")
	_check("one part rejected", DepResolver.parse_dep("justone@v1"), null)
	_check("four parts rejected", DepResolver.parse_dep("a/b/c/d@v1"), null)

	var list = DepResolver.parse_dep_list('["a/b@v1", \'c/d\' , bad, "e/f@2"]')
	_check("list skips malformed", list.map(func(x): return x.repo_id),
		["github.com/a/b", "github.com/c/d", "github.com/e/f"])
	_check("empty list", DepResolver.parse_dep_list("[]").size(), 0)


static func _test_cfg_keys() -> void:
	var both = '[plugin]\nname="x"\ndeps=["a/b@v1"]\nrequire=["c/d@v2"]\n'
	_check("require wins", DepResolver.deps_in_cfg_text(both).map(func(x): return x.repo_id), ["github.com/c/d"])
	var empty_require = '[plugin]\ndeps=["a/b@v1"]\nrequire=[]\n'
	_check("empty require still wins", DepResolver.deps_in_cfg_text(empty_require).size(), 0)
	var other_section = '[other]\ndeps=["a/b@v1"]\n[plugin]\nname="x"\n'
	_check("only [plugin] is read", DepResolver.deps_in_cfg_text(other_section).size(), 0)


static func _test_repo_id() -> void:
	_check("www and .git stripped", DepResolver.repo_id_from_url("https://www.github.com/Brohd11/X.git"), "github.com/brohd11/x")
	_check("scp remote", DepResolver.repo_id_from_url("git@github.com:o/R.git"), "github.com/o/r")
	_check("file url", DepResolver.repo_id_from_url("file:///tmp/a/o/r.git"), "local/o/r")
	_check("garbage", DepResolver.repo_id_from_url("nope"), "")


static func _test_compare_tags() -> void:
	_check("numeric not lexical", DepResolver.compare_tags("v1.0.10", "v1.0.9"), 1)
	_check("missing parts are zero", DepResolver.compare_tags("1.0", "v1.0.0"), 0)
	_check("pre-release suffix ignored", DepResolver.compare_tags("v1.2.0-beta", "1.2.0"), 0)
	_check("older", DepResolver.compare_tags("v0.9", "v1"), -1)
	_check("date is incomparable", DepResolver.compare_tags("2024-01-02", "v1"), DepResolver.TAGS_INCOMPARABLE)


## T requires A@1.0 and B@1.0; B requires A@1.2. A@1.2 needs C, while only A@1.0 needs D - so A
## resolves to 1.2, C is in, and D is pruned with the version that asked for it.
static func _test_mvs() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1.0.0", {"plugin.cfg": '[plugin]\nversion="1.0.0"\ndeps=["me/a@v1.0.0", "me/b@v1.0.0"]\n'})
	f.add("me/a", "v1.0.0", {"version.cfg": '[plugin]\nversion="1.0.0"\npath="addons/lib/a"\ndeps=["me/d@v1"]\n'})
	f.add("me/a", "v1.2.0", {"version.cfg": '[plugin]\nversion="1.2.0"\npath="addons/lib/a"\ndeps=["me/c@v1"]\n'})
	f.add("me/b", "v1.0.0", {"plugin.cfg": '[plugin]\nrequire=["me/a@v1.2.0", "me/t@v1.0.0"]\n'})
	f.add("me/c", "v1", {})
	f.add("me/d", "v1", {})

	var r = DepResolver.new(f, {"github.com/me/b": "res://addons/b", "github.com/me/c": "res://addons/c"})
	var lock = r.resolve(t, "1.0.0", "res://addons/t")
	_check("mvs: no errors " + str(r.errors), r.errors.is_empty(), true)
	if lock.is_empty():
		return
	var got = {}
	for e in lock.deps:
		got[e.repo_id] = [e.tag, e.path]
	_check("mvs: selection", got, {
		"github.com/me/a": ["v1.2.0", "res://addons/lib/a"],
		"github.com/me/b": ["v1.0.0", "res://addons/b"],
		"github.com/me/c": ["v1", "res://addons/c"],
	})
	_check("mvs: target tag", lock.target.tag, "v1.0.0")
	_check("mvs: remote source", lock.target.source, "remote")
	_check("mvs: sha recorded", lock.target.sha != "", true)
	_check("mvs: hash stable", DepResolver.lock_hash(lock), DepResolver.lock_hash(lock.duplicate(true)))


static func _test_tag_v_toggle() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "1.0.0", {"plugin.cfg": '[plugin]\ndeps=["me/a@1.0.0"]\n'})
	f.add("me/a", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/a"\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "1.0.0", "res://addons/t")
	_check("v toggle: resolved " + str(r.errors), lock.is_empty(), false)
	if not lock.is_empty():
		_check("v toggle: dep tag is the real tag", lock.deps[0].tag, "v1.0.0")


static func _test_failures() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1.0.0", {"plugin.cfg": '[plugin]\ndeps=["me/a@v1.0.0", "me/untagged"]\n'})
	f.add("me/a", "v1.0.0", {"version.cfg": '[plugin]\npath="addons/a"\n'})
	var r = DepResolver.new(f)
	_check("untagged: empty lock", r.resolve(t, "1.0.0", "res://addons/t"), {})
	_check("untagged: chain in error " + str(r.errors),
		r.errors.size() == 1 and "github.com/me/t -> github.com/me/untagged" in r.errors[0], true)

	var f2 = FakeFetcher.new()
	var t2 = f2.add("me/t", "v1.0.0", {"plugin.cfg": '[plugin]\ndeps=["me/a@v9"]\n'})
	f2.add("me/a", "v1.0.0", {})
	var r2 = DepResolver.new(f2)
	_check("missing tag: empty lock", r2.resolve(t2, "1.0.0", "res://addons/t"), {})
	_check("missing tag: named", r2.errors.size() == 1 and "tag v9 not found" in r2.errors[0], true)

	var r3 = DepResolver.new(f2)
	_check("untagged target version", r3.resolve(t2, "2.0.0", "res://addons/t"), {})
	_check("untagged target: named", r3.errors.size() == 1 and "no tag for version 2.0.0" in r3.errors[0], true)

	var f4 = FakeFetcher.new()
	var t4 = f4.add("me/t", "v1", {"plugin.cfg": '[plugin]\ndeps=["me/a@v1"]\n'})
	f4.add("me/a", "v1", {})
	var r4 = DepResolver.new(f4)
	_check("no install path: empty lock", r4.resolve(t4, "v1", "res://addons/t"), {})
	_check("no install path: named", r4.errors.size() == 1 and "no install path" in r4.errors[0], true)


static func _test_cycle() -> void:
	var f = FakeFetcher.new()
	var t = f.add("me/t", "v1", {"plugin.cfg": '[plugin]\ndeps=["me/a@v1"]\n'})
	f.add("me/a", "v1", {"version.cfg": '[plugin]\npath="addons/a"\ndeps=["me/b@v1"]\n'})
	f.add("me/b", "v1", {"version.cfg": '[plugin]\npath="addons/b"\ndeps=["me/a@v1"]\n'})
	var r = DepResolver.new(f)
	var lock = r.resolve(t, "v1", "res://addons/t")
	_check("cycle: terminates with both " + str(r.errors), lock.get("deps", []).size(), 2)


## --local: target and dep are fetched through override urls, but ids stay canonical - so a dep's
## requirement back on the target is still recognized as the target and skipped.
static func _test_local_override() -> void:
	var f = FakeFetcher.new()
	f.repos["file:///dev/addons/t"] = {"v1": {"plugin.cfg": '[plugin]\ndeps=["me/a@v1"]\n'}}
	f.repos["file:///dev/addons/a"] = {"v1": {"version.cfg": '[plugin]\npath="addons/a"\ndeps=["me/t@v1"]\n'}}
	var r = DepResolver.new(f, {}, {
		"github.com/me/t": "file:///dev/addons/t",
		"github.com/me/a": "file:///dev/addons/a",
	})
	var lock = r.resolve("https://github.com/me/t", "v1", "res://addons/t")
	_check("local: resolved " + str(r.errors), lock.is_empty(), false)
	if lock.is_empty():
		return
	_check("local: target id canonical", lock.target.repo_id, "github.com/me/t")
	_check("local: target fetched locally", [lock.target.url, lock.target.source], ["file:///dev/addons/t", "local"])
	_check("local: self requirement skipped", lock.deps.map(func(e): return e.repo_id), ["github.com/me/a"])
	_check("local: dep source", lock.deps[0].source, "local")


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])
