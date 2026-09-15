@tool
extends EditorScript

## Tests for the release export's repo cache against real git. The "remote" is a throwaway bare
## clone of a tagged addon in this project, so nothing is committed and nothing hits the network.
## Skips when that addon or its tag is missing, rather than failing on an unrelated checkout.
##
##     load("res://tests/plugin_exporter/repo_cache_test.gd").run_tests()

const RepoCache = preload("res://addons/plugin_exporter/src/class/release/repo_cache.gd")

const SOURCE_REPO = "res://addons/addon_lib/editor_node_ref"
const TAG = "v0.3.2"
const DIR = "user://pe_repo_cache_tests"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	var output:Array[String] = []

	var source = ProjectSettings.globalize_path(SOURCE_REPO)
	if _git(["-C", source, "rev-parse", "-q", "--verify", TAG + "^{commit}"]).exit != 0:
		output.append("repo_cache: skipped (%s has no tag %s)" % [SOURCE_REPO, TAG])
		return {"result": 0, "output": output}

	var root = ProjectSettings.globalize_path(DIR)
	_reset(root)
	var remote = root.path_join("remote/editor_node_ref.git")
	_git(["clone", "--bare", "--quiet", source, remote])
	var url = "file://" + remote

	_test_fetch_and_read(root, url)
	_test_list_and_stage(root, url)
	_test_offline_cache_hit(root, url, remote)
	_test_moved_tag(root, source)
	_test_local_retag(root, source)
	_test_local_mirror_keys(root)

	_reset(root)
	output.append("repo_cache: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _test_fetch_and_read(root:String, url:String) -> void:
	var cache = RepoCache.new(root.path_join("cache"))
	var sha = cache.tag_sha(url, TAG)
	_check("tag sha matches source " + cache.last_error,
		sha, _git(["-C", ProjectSettings.globalize_path(SOURCE_REPO), "rev-parse", TAG + "^{commit}"]).output.strip_edges())
	_check("missing tag is empty", cache.tag_sha(url, "v999.0.0"), "")
	var cfg = cache.read_file(url, TAG, "version.cfg")
	_check("read cfg at tag", cfg is String and 'version="0.3.2"' in cfg, true)
	_check("missing file is null", cache.read_file(url, TAG, "nope.cfg"), null)

	var dest = root.path_join("extract")
	_check("extract ok " + cache.last_error, cache.extract(url, TAG, dest), true)
	_check("extracted cfg", FileAccess.file_exists(dest.path_join("version.cfg")), true)
	_check("mirror has no index", FileAccess.file_exists(cache.mirror_path(url).path_join("index")), false)


static func _test_list_and_stage(root:String, url:String) -> void:
	var cache = RepoCache.new(root.path_join("cache"))
	_check("list_files has version.cfg", "version.cfg" in cache.list_files(url, TAG), true)
	_check("list_files for a missing tag", cache.list_files(url, "v999.0.0"), [])
	var staged = cache.stage(url, TAG)
	_check("stage extracts " + cache.last_error, FileAccess.file_exists(staged.path_join("version.cfg")), true)
	_check("stage is reused", cache.stage(url, TAG), staged)
	_check("stage marker stays outside the tree", DirAccess.get_files_at(staged).has(".staged"), false)


## The whole point of the cache: once a tag is mirrored, the remote can vanish.
static func _test_offline_cache_hit(root:String, url:String, remote:String) -> void:
	var moved_remote = remote + ".away"
	DirAccess.rename_absolute(remote, moved_remote)
	var cache = RepoCache.new(root.path_join("cache"))
	_check("cached tag without remote " + cache.last_error, cache.tag_sha(url, TAG) != "", true)
	DirAccess.rename_absolute(moved_remote, remote)


## Re-point the tag on a fresh remote and confirm only a refresh notices.
static func _test_moved_tag(root:String, source:String) -> void:
	var remote = root.path_join("remote/moving.git")
	_git(["clone", "--bare", "--quiet", source, remote])
	var url = "file://" + remote
	var cache_dir = root.path_join("cache_moving")

	var first = RepoCache.new(cache_dir).tag_sha(url, TAG)
	var other = _git(["--git-dir=" + remote, "rev-parse", TAG + "^{commit}~1"]).output.strip_edges()
	if other == "":
		_failures.append("moved tag: source tag has no parent commit to move to")
		return
	_git(["--git-dir=" + remote, "tag", "-f", TAG, other])

	_check("no refresh keeps cached sha", RepoCache.new(cache_dir).tag_sha(url, TAG), first)
	var refreshing = RepoCache.new(cache_dir, true)
	_check("refresh rejects moved tag", refreshing.tag_sha(url, TAG), "")
	_check("refresh names the move", "moved upstream" in refreshing.last_error, true)


## --local: checkouts get re-tagged while iterating, so a local url follows a moved tag without
## refresh and without treating it as an error.
static func _test_local_retag(root:String, source:String) -> void:
	var remote = root.path_join("remote/local_moving.git")
	_git(["clone", "--bare", "--quiet", source, remote])
	var url = "file://" + remote
	var cache_dir = root.path_join("cache_local")

	RepoCache.new(cache_dir).tag_sha(url, TAG)
	var other = _git(["--git-dir=" + remote, "rev-parse", TAG + "^{commit}~1"]).output.strip_edges()
	_git(["--git-dir=" + remote, "tag", "-f", TAG, other])

	var local = RepoCache.new(cache_dir)
	local.local_urls[url] = true
	_check("local url follows moved tag " + local.last_error, local.tag_sha(url, TAG), other)
	_check("local re-tag is not an error", local.last_error, "")


static func _test_local_mirror_keys(root:String) -> void:
	var cache = RepoCache.new(root.path_join("cache"))
	_check("file urls sharing a basename get separate mirrors",
		cache.mirror_path("file:///a/x/repo") != cache.mirror_path("file:///b/x/repo"), true)


static func _reset(root:String) -> void:
	if DirAccess.dir_exists_absolute(root):
		OS.move_to_trash(root)


static func _git(args:Array) -> Dictionary:
	var output = []
	var code = OS.execute("git", args, output, true)
	return {"exit": code, "output": "".join(output)}


static func _check(label:String, got, expected) -> void:
	if got == expected:
		_passed += 1
		return
	_failures.append("%s (expected %s, got %s)" % [label, expected, got])
