@tool
extends EditorScript

## Tests for release-asset dependencies: gdaddon's AutoAsset pick, and cached releases resolving
## and staging without the network. The cache is laid out by hand with download urls that could
## never resolve, so any accidental fetch fails the test instead of passing quietly.
##
##     load("res://tests/plugin_exporter/release_cache_test.gd").run_tests()

const ReleaseCache = preload("res://addons/plugin_exporter/src/class/release/release_cache.gd")
const ReleaseRunner = preload("res://addons/plugin_exporter/src/class/release/release_runner.gd")

const DIR = "user://pe_release_cache_tests"
const REPO = "https://github.com/me/yaml"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	var root = ProjectSettings.globalize_path(DIR)
	ReleaseRunner.remove_dir(root)

	_test_auto_asset()
	_test_non_github(root)
	_test_cached_release(root)
	_test_recent_no_release(root)

	ReleaseRunner.remove_dir(root)
	var output:Array[String] = []
	output.append("release_cache: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _test_auto_asset() -> void:
	var one = {"tag_name": "v1", "assets": [{"name": "a.zip", "browser_download_url": "https://x/a.zip"}]}
	_check("one upload is picked", ReleaseCache.auto_asset(one), {"name": "a.zip", "url": "https://x/a.zip"})
	_check("no uploads means source", ReleaseCache.auto_asset({"tag_name": "v1", "assets": []}), {})
	var two = ReleaseCache.auto_asset({"tag_name": "v1", "assets": [{"name": "a.zip"}, {"name": "a-backport.zip"}]})
	_check("two uploads are ambiguous", two.has("error") and "a-backport.zip" in two.error, true)


static func _test_non_github(root:String) -> void:
	_check("non-GitHub hosts use source", ReleaseCache.new(root).lookup("https://gitlab.com/o/r", "v1").state, "none")


## yaml-parser-2.1.0.zip's shape: wrapper folder, addon path relative to addons/, macOS junk.
static func _test_cached_release(root:String) -> void:
	var cache = ReleaseCache.new(root)
	var dir = cache.release_dir(REPO, "v2.1.0")
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join("release.json"), JSON.stringify({"tag_name": "v2.1.0",
		"assets": [{"name": "yaml-parser-2.1.0.zip", "browser_download_url": "https://invalid.invalid/y.zip"}]}))
	var zip_path = dir.path_join("yaml-parser-2.1.0.zip")
	var packer = ZIPPacker.new()
	packer.open(zip_path)
	for entry in ["yaml-parser-2.1.0/addon_lib/yaml_parser/version.cfg", "yaml-parser-2.1.0/addon_lib/yaml_parser/yaml.gd",
			"__MACOSX/yaml-parser-2.1.0/._x"]:
		packer.start_file(entry)
		packer.write_file('[plugin]\nversion="2.1.0"\n'.to_utf8_buffer())
		packer.close_file()
	packer.close()

	var found = cache.lookup(REPO, "v2.1.0")
	_check("cached: asset " + cache.last_error, [found.get("state"), found.get("asset")], ["asset", "yaml-parser-2.1.0.zip"])
	_check("cached: sha is the zip's", found.get("sha"), FileAccess.get_sha256(zip_path))

	var files = cache.files(REPO, "v2.1.0", "yaml-parser-2.1.0.zip")
	_check("cached: files listed", "yaml-parser-2.1.0/addon_lib/yaml_parser/version.cfg" in files, true)
	_check("cached: junk not staged", files.any(func(f): return f.begins_with("__MACOSX")), false)
	_check("cached: stage is reused", cache.stage(REPO, "v2.1.0", "yaml-parser-2.1.0.zip"), dir.path_join("staging"))


static func _test_recent_no_release(root:String) -> void:
	var cache = ReleaseCache.new(root)
	var dir = cache.release_dir("https://github.com/me/norelease", "v1")
	_write(dir.path_join(ReleaseCache.NO_RELEASE_MARKER), str(int(Time.get_unix_time_from_system())))
	_check("recent 404 is trusted", cache.lookup("https://github.com/me/norelease", "v1").state, "none")


static func _write(path:String, text:String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])
