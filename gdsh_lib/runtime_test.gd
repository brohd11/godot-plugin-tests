extends SceneTree

const Sh = preload("res://addons/addon_lib/gdsh/gdsh.gd")
const Manifest = preload("res://addons/addon_lib/gdsh_lib/utils/manifest.gd")
const UTILS = "res://addons/addon_lib/gdsh_lib/utils"
const FIXTURES = "res://tests/gdsh_lib/fixtures"
var checks = 0
var failures = 0


func _initialize():
	_run.call_deferred()


func _run():
	_test_loading()
	_test_streams()
	_test_paths()
	_test_filesystem()
	_test_class()
	print("GDSh utils: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)


func check(condition:bool, label:String):
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + label)


func equal(actual, expected, label:String):
	check(actual == expected, "%s (expected %s, got %s)" % [label, str(expected), str(actual)])


func session() -> Sh.Context:
	var ctx = Sh.Context.new()
	ctx.load(UTILS, true)
	return ctx


func run(text:String, stdin:="", ctx:Sh.Context=null) -> Sh.Context:
	var result = Sh.Context.new_ctx("test", ctx if ctx != null else session())
	result.stdin = stdin
	Sh.Execute.execute_command_multiline(text, result)
	return result


func out(text:String, stdin:="", ctx:Sh.Context=null) -> String:
	return run(text, stdin, ctx).stdout.strip_edges()


func _test_loading():
	var scopes = Sh.Load.load_directory(UTILS)
	equal(scopes.size(), Manifest.COMMANDS.size(), "directory loads exactly the manifest commands")
	check(not scopes.has("manifest"), "manifest.gd is not loaded as a command")
	for script in Manifest.COMMANDS:
		check(scopes.has(script.get_command_name()), "manifest command loads: " + script.get_command_name())
	var ctx = session()
	check(not Sh.Completion.new("", ctx).get_completions().has("cat"), "utils load as hidden commands")
	var hidden_choices = Sh.Completion.new("hidden ", ctx).get_completions()
	check(hidden_choices.has("utils") and not hidden_choices.has("grep"), "hidden lists the utils namespace, not its children")
	check(Sh.Completion.new("utils ", ctx).get_completions().has("grep"), "utils namespace lists its commands")
	equal(out("utils count", "a\nb", ctx), "2", "utils namespace routes to a command")


func _test_streams():
	var lines = "alpha\nbeta\ngamma\n"
	equal(out("count", lines), "3", "count lines")
	equal(out("count --words", "a b\nc"), "3", "count words")
	equal(out("head 2", lines), "alpha\nbeta", "head")
	equal(out("tail 1", lines), "gamma", "tail")
	equal(out("grep et", lines), "beta", "grep substring")
	equal(out("grep --regex ^g", lines), "gamma", "grep regex")
	equal(out("strip_edges", "  padded  "), "padded", "strip_edges")
	equal(out("math 2 + 3"), "5", "math")
	equal(out("xargs echo", "one 'two words'\nthree"), "one two words three", "xargs keeps quoted words")
	equal(out("echo a | hidden utils count"), "1", "utils route through hidden and their namespace")


func _test_paths():
	var ctx = session()
	ctx.cwd = FIXTURES
	var listing = out("ls", "", ctx).split("\n")
	check(listing.has("sample.txt") and listing.has("nested/"), "ls lists files and directories: " + str(listing))
	check(out("ls --recursive", "", ctx).split("\n").has("nested/inner.txt"), "ls --recursive walks res:// by default")
	check(out("find inner", "", ctx).split("\n").has(FIXTURES + "/nested/inner.txt"), "find matches file names")
	equal(out("cat sample.txt", "", ctx), "sample text", "cat resolves paths from cwd")
	ctx.host_data["file_paths"] = func(directories): return PackedStringArray([] if directories else [FIXTURES + "/cached.txt"])
	equal(out("find cached", "", ctx), FIXTURES + "/cached.txt", "find uses the host file_paths hook")


func _test_filesystem():
	var root = "user://gdsh_lib_filesystem_test"
	for path in [root + "/b", root + "/a", root]:
		DirAccess.remove_absolute(path)
	var ctx = session()
	var changes = [0]
	ctx.host_data["filesystem_changed"] = func(): changes[0] += 1
	equal(run("mkdir " + root + "/a", "", ctx).exit_code, 0, "mkdir succeeds")
	check(DirAccess.dir_exists_absolute(root + "/a"), "mkdir creates the directory")
	equal(run("mv " + root + "/a " + root + "/b", "", ctx).exit_code, 0, "mv succeeds")
	check(DirAccess.dir_exists_absolute(root + "/b") and not DirAccess.dir_exists_absolute(root + "/a"), "mv renames the directory")
	equal(changes[0], 2, "mkdir and mv notify the host")
	equal(run("mkdir " + root + "/c").exit_code, 0, "file commands work without a host hook")
	for path in [root + "/b", root + "/c", root]:
		DirAccess.remove_absolute(path)


func _test_class():
	var result = run("class Node")
	check(result.exit_code == 0 and result.stdout.contains("Node[/color] : ") and result.stdout.contains("methods ("), "class summarizes an engine class")
	check(out("class --inherits Node2D").contains("CanvasItem"), "class prints the inheritance chain")
	equal(run("class GDSh").exit_code, 0, "class resolves global script classes")
	equal(run("class NoSuchClassAnywhere").exit_code, 1, "unknown class fails")
