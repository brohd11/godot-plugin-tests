extends RefCounted
## gdsh_lib runtime checks, driven by runtime_test.gd (headless and editor console `test`).

const Sh = preload("res://addons/addon_lib/gdsh/_ns/gd_sh.gd")
const Manifest = preload("res://addons/addon_lib/gdsh_lib/utils/manifest.gd")
const UTILS = "res://addons/addon_lib/gdsh_lib/utils"
const FIXTURES = "res://tests/gdsh_lib/fixtures"
const TREE = "res://addons/addon_lib/gdsh_lib/tree/tree.gd"
const TreeManifest = preload("res://addons/addon_lib/gdsh_lib/tree/manifest.gd")
var checks = 0
var failures = 0
var report:Array[String] = []


func run_sync():
	_test_loading()
	_test_streams()
	_test_str()
	_test_paths()
	_test_filesystem()
	_test_class()
	_test_tree()


func finish() -> Array[String]:
	report.append("GDSh utils: %d checks, %d failures" % [checks, failures])
	return report


## The running tree: the headless runner's SceneTree or the editor's.
func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func check(condition:bool, label:String):
	checks += 1
	if not condition:
		failures += 1
		report.append("FAIL: " + label)


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
	equal(out("grep -iv ALPHA", lines), "beta\ngamma", "grep groups short flags")
	var bad_short = run("grep -ix a", lines)
	check(bad_short.exit_code != 0 and bad_short.stderr.contains("Unrecognized flag: -x"), "unknown short flag letter errors")
	check(run("grep --help").stdout.contains("-i, --ignore-case"), "help lists short forms")
	var after_short = Sh.Completion.new("grep -i ", session()).get_completions()
	check(not after_short.has("--ignore-case") and after_short.has("--invert"), "completion hides flags given in short form")
	equal(out("math 2 + 3"), "5", "math")
	equal(out("xargs echo", "one 'two words'\nthree"), "one two words three", "xargs keeps quoted words")
	equal(out("echo a | hidden utils count"), "1", "utils route through hidden and their namespace")


func _test_str():
	var children = Sh.Load.load_directory(UTILS.path_join("str"), true)
	equal(children.size(), Manifest.STR_COMMANDS.size(), "manifest preloads every str subcommand")
	var ctx = session()
	check(not Sh.Completion.new("hidden ", ctx).get_completions().has("str"), "str stays under the utils namespace")
	check(Sh.Completion.new("utils ", ctx).get_completions().has("str"), "utils lists str")
	var ops = Sh.Completion.new("str ", ctx).get_completions()
	check(ops.has("basedir") and ops.has("strip_edges") and not ops.has("str_util") and not ops.has("match_base"), "str completes its ops, not its shared scripts")
	check(not Sh.Completion.new("", ctx).get_completions().has("strip_edges"), "strip_edges moved under str")

	equal(out("str basedir res://a/b.gd"), "res://a", "basedir")
	equal(out("str file res://a/b.gd"), "b.gd", "file")
	equal(out("str basename res://a/b.gd"), "res://a/b", "basename")
	equal(out("str extension res://a/b.gd"), "gd", "extension")
	equal(out("str join c.gd res://a"), "res://a/c.gd", "join")
	equal(out("str file", "res://a/x.gd\nres://b/y.tscn\n"), "x.gd\ny.tscn", "ops map stdin lines")
	equal(run("str extension", "a\nb.gd").stdout, "\ngd\n", "empty results keep lines aligned")

	var paths = "res://a.gd\nuser://b.gd\nres://c.tscn\n"
	equal(out("str ends_with .gd", paths), "res://a.gd\nuser://b.gd", "ends_with filters stdin")
	equal(out("str begins_with res:// | str file", paths), "a.gd\nc.tscn", "predicates pipe into ops")
	equal(run("str ends_with .png", paths).exit_code, 1, "no match fails")
	var bool_hit = run("str contains -b foo xfoo")
	check(bool_hit.exit_code == 0 and bool_hit.stdout == "", "--bool prints nothing on a match")
	equal(run("str contains --bool foo bar").exit_code, 1, "--bool fails without a match")
	equal(out("str contains -i FOO xfoo"), "xfoo", "--ignore-case")
	equal(run("str ends_with -bi .GD a.gd").exit_code, 0, "match short flags group")
	equal(out("if str begins_with -b res:// res://x { echo local } else { echo other }"), "local", "predicates drive if")
	equal(out('str begins_with "-x" "-xy"'), "-xy", "quoted dash words are literal")

	equal(out("str trim_prefix res:// res://a/b"), "a/b", "trim_prefix")
	equal(out("str trim_suffix .gd a.gd"), "a", "trim_suffix")
	equal(out("str replace / . a/b/c"), "a.b.c", "replace")
	equal(out("str replace -i A x aAa"), "xxx", "replace --ignore-case")
	equal(out("str upper abc"), "ABC", "upper")
	equal(out("str lower ABC"), "abc", "lower")
	equal(out("str slice / 1 a/b/c"), "b", "slice")
	equal(out("str slice / -1 a/b/c"), "c", "slice negative index")
	equal(run("str slice / 5 a/b").stdout, "\n", "slice out of range prints an empty line")
	var bad_index = run("str slice / x a/b")
	check(bad_index.exit_code != 0 and bad_index.stderr.contains("Index must be an integer"), "slice rejects a non-int index")
	equal(out("str length hello"), "5", "length")
	equal(out('str length ""'), "0", "an empty text argument is input")
	equal(out("str strip_edges", "  padded  "), "padded", "strip_edges")
	equal(out("str strip_edges", "  a  \n b "), "a\nb", "strip_edges maps lines")
	equal(run("str strip_edges --left", " a ").stdout, "a \n", "--left keeps trailing whitespace")
	var no_input = run("str upper")
	check(no_input.exit_code != 0 and no_input.stderr.contains("No input"), "ops without input fail")


func _test_paths():
	var ctx = session()
	ctx.cwd = FIXTURES
	var listing = out("ls", "", ctx).split("\n")
	check(listing.has("sample.txt") and listing.has("nested/"), "ls lists files and directories: " + str(listing))
	check(out("ls --recursive", "", ctx).split("\n").has("nested/inner.txt"), "ls --recursive walks res:// by default")
	check(out("ls -r", "", ctx).split("\n").has("nested/inner.txt"), "ls -r is --recursive")
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


func _test_tree():
	var children = Sh.Load.load_directory(TREE.get_base_dir(), true)
	equal(children.size() + 1, TreeManifest.COMMANDS.size(), "manifest preloads the tree namespace and every subcommand")
	# Main is a scene root; A and L2 belong to its scene, L1 has no owner.
	var main = Node.new()
	main.name = "Main"
	var panel = Node2D.new()
	panel.name = "A"
	main.add_child(panel)
	var label = Label.new()
	label.name = "L1"
	panel.add_child(label)
	var other = Label.new()
	other.name = "L2"
	main.add_child(other)
	_tree().root.add_child(main)
	panel.owner = main
	other.owner = main
	var p = "/root/Main"

	var ctx = session()
	ctx.load(TREE)
	check(ctx.scopes.has("tree") and not ctx.scopes.has("add"), "tree loads as one namespace")
	check(Sh.Completion.new("tree ", ctx).get_completions().has("free"), "tree completes its subcommands")
	equal(out("tree root", "", ctx), "/root", "root prints /root")
	check(out("tree root | tree nodes", "", ctx).split("\n").has(p), "root pipes into nodes")
	equal(out("echo %s | tree nodes" % p, "", ctx), p + "/A\n" + p + "/L2", "nodes lists direct children")
	equal(out("echo %s | tree nodes --recursive Label" % p, "", ctx), p + "/A/L1\n" + p + "/L2", "--recursive walks descendants; classes match inheriting classes")
	equal(out("echo %s | tree nodes --recursive --exact CanvasItem" % p, "", ctx), "", "--exact skips inheriting classes")
	var no_stdin = run("tree nodes", "", ctx)
	check(no_stdin.exit_code != 0 and no_stdin.stderr.contains("No node paths on stdin"), "nodes requires stdin paths")
	var relative = run("echo Main | tree nodes", "", ctx)
	check(relative.exit_code != 0 and relative.stderr.contains("Not an absolute node path: Main"), "relative paths are rejected")
	equal(out("echo %s | tree nodes --include-self" % p, "", ctx), "\n".join([p, p + "/A", p + "/L2"]), "--include-self lists the input before its children")
	equal(out("echo %s | tree nodes --include-self Label" % p, "", ctx), p + "/L2", "--include-self inputs still go through filters")
	equal(out("echo %s | tree nodes -ir" % p, "", ctx), out("echo %s | tree nodes --include-self --recursive" % p, "", ctx), "tree nodes short flags group")
	var captured = out('X=$(echo %s | tree nodes -ip); echo "$X"' % p, "", ctx)
	check(not captured.contains("[color=") and captured.contains("Main"), "substitution captures pretty output as plain text: " + captured)
	equal(out("echo %s | tree nodes --include-self --owned --recursive" % p, "", ctx), "\n".join([p, p + "/A", p + "/L2"]), "--owned keeps a scene root input and hides unowned nodes")
	var pretty = out("echo %s | tree nodes --include-self --pretty" % p, "", ctx).split("\n")
	check(pretty.size() == 3 and pretty[0].contains("Main") and pretty[1].begins_with("  "), "--include-self --pretty indents children under the input: " + str(pretty))

	equal(out("echo %s | tree add Node2D X" % p, "", ctx), p + "/X", "add prints the new absolute path")
	check(main.get_node("X").owner == main, "a child of a scene root is owned by it")
	equal(out("echo %s/A | tree add Label T" % p, "", ctx), p + "/A/T", "add under a nested parent")
	check(main.get_node("A/T").owner == main, "a nested child joins the parent's scene")
	equal(out("echo %s | tree nodes --recursive --owned" % p, "", ctx), "\n".join([p + "/A", p + "/A/T", p + "/L2", p + "/X"]), "--owned hides nodes outside the input's scene")
	equal(out("echo %s | tree nodes --recursive Node2D | tree add Label Tag" % p, "", ctx), p + "/A/Tag\n" + p + "/X/Tag", "add under every piped parent")

	equal(out("echo %s/L2 | tree prop text Hi" % p, "", ctx), "Hi", "prop sets and prints the value")
	equal(out("echo %s/L2 | tree prop text --verbose" % p, "", ctx), p + "/L2.text = Hi", "prop --verbose prints path and property")
	equal(out("echo %s/L2 | tree prop text -v" % p, "", ctx), p + "/L2.text = Hi", "prop -v is --verbose")
	equal(other.text, "Hi", "prop applies without undo")
	out("echo %s/A | tree prop position:x 5" % p, "", ctx)
	equal(panel.position.x, 5.0, "prop converts nested values")
	equal(out("echo %s/L2 | tree rename Caption" % p, "", ctx), p + "/Caption", "rename prints the new path")
	equal(out("echo %s/Caption | tree reparent %s/A" % [p, p], "", ctx), p + "/A/Caption", "reparent prints the new path")
	check(other.owner == main, "reparented nodes join the new parent's scene")
	var bad_parent = run("echo %s/A/Caption | tree reparent A" % p, "", ctx)
	check(bad_parent.exit_code != 0 and bad_parent.stderr.contains("Not an absolute node path: A"), "reparent requires an absolute parent path")
	out("echo %s/A | tree group add g" % p, "", ctx)
	check(panel.is_in_group("g"), "group add")

	var pack_path = "user://gdsh_tree_pack_test.tscn"
	equal(out("echo %s/A | tree pack %s" % [p, pack_path], "", ctx), pack_path, "pack prints the destination")
	var packed = load(pack_path)
	var packed_node = packed.instantiate() if packed is PackedScene else null
	check(packed_node != null and packed_node.has_node("L1") and packed_node.has_node("Caption"), "pack saves the subtree, including unowned nodes")
	check(label.owner == null and other.owner == main, "pack leaves live owners unchanged")
	if packed_node != null:
		packed_node.free()
	var ext_pack = "user://gdsh_tree_pack_ext"
	equal(out("echo %s | tree pack %s" % [p, ext_pack], "", ctx), ext_pack + ".tscn", "pack adds .tscn")
	for path in [pack_path, ext_pack + ".tscn"]:
		DirAccess.remove_absolute(path)
	equal(run("tree pack user://gdsh_tree_never.tscn", "", ctx).exit_code, 1, "pack requires a stdin node")

	var root_free = run("tree root | tree free", "", ctx)
	check(root_free.exit_code != 0 and root_free.stderr.contains("Refusing to free the SceneTree root") and main.is_inside_tree(), "free refuses /root")
	var missing = run("echo %s/Nope | tree free" % p, "", ctx)
	check(missing.exit_code != 0 and missing.stderr.contains("Node not found: " + p + "/Nope"), "free reports missing paths")
	equal(run("echo %s | tree nodes --recursive Label | tree free" % p, "", ctx).exit_code, 0, "piped free succeeds")
	equal(out("echo %s | tree nodes --recursive Label" % p, "", ctx), "", "free removes every piped node")
	equal(run("echo %s | tree nodes --recursive Label | tree free" % p, "", ctx).exit_code, 1, "free after an empty pipe stage does nothing")

	var undo_redo = UndoRedo.new()
	ctx.host_data["undo_redo"] = func(): return undo_redo
	out("echo %s | tree add Node Undone" % p, "", ctx)
	check(main.has_node("Undone"), "add applies through the injected UndoRedo")
	undo_redo.undo()
	check(not main.has_node("Undone"), "undo removes the added node")
	undo_redo.redo()
	check(main.has_node("Undone"), "redo restores it")
	out("echo %s/A | tree prop position:x 9" % p, "", ctx)
	undo_redo.undo()
	equal(panel.position.x, 5.0, "undo restores a property")
	out("echo %s/Undone | tree free" % p, "", ctx)
	check(not main.has_node("Undone"), "free applies through UndoRedo")
	undo_redo.undo()
	check(main.has_node("Undone"), "undo restores a freed node")
	undo_redo.free()

	# Compound: many tree commands become one undo entry, applied as they run.
	var box = Node.new()
	box.name = "Box"
	main.add_child(box)
	box.owner = main
	for child_name in ["B0", "Spacer", "B1"]:
		var child = Label.new() if child_name != "Spacer" else Node.new()
		child.name = child_name
		box.add_child(child)
		child.owner = main
	var add_icons = """add_icons(){
	local nodes=$(echo "$1" | tree nodes -r --type=Label)
	for n in $nodes {
		local parent=$(echo "$n" | tree parent)
		local idx=$(echo "$n" | tree index)
		local h=$(echo "$parent" | tree add HBoxContainer H)
		echo "$n" | tree reparent "$h" 1>discard
		echo "$h" | tree add TextureRect Icon 1>discard
		echo "$h" | tree index $idx 1>discard
	}
}
add_icons %s/Box""" % p
	var before = tree_shape(box)
	var compound_redo = UndoRedo.new()
	ctx.host_data["undo_redo"] = func(): return compound_redo
	equal(run("undoredo commit", "", ctx).exit_code, 1, "commit needs an open compound")
	equal(run("undoredo --compound Icons", "", ctx).exit_code, 0, "--compound opens")
	run(add_icons, "", ctx)
	var after = tree_shape(box)
	check(after != before and box.get_child(0) is HBoxContainer and box.get_child(0).get_child(0).name == "B0", "compound changes apply while open: " + after)
	equal(compound_redo.get_history_count(), 0, "open compound registers nothing")
	check(run("undoredo", "", ctx).stdout.contains("8 change(s)"), "status counts buffered commands")
	run("undoredo commit", "", ctx)
	equal(compound_redo.get_history_count(), 1, "commit registers one entry")
	equal(compound_redo.get_current_action_name(), "Icons", "commit uses the compound name")
	equal(tree_shape(box), after, "commit does not re-run changes")
	compound_redo.undo()
	equal(tree_shape(box), before, "one undo reverts the whole compound")
	compound_redo.redo()
	equal(tree_shape(box), after, "redo reapplies the whole compound")
	compound_redo.undo()

	run("undoredo --compound", "", ctx)
	run(add_icons, "", ctx)
	check(tree_shape(box) != before, "compound applies before cancel")
	equal(run("undoredo cancel", "", ctx).exit_code, 0, "cancel succeeds")
	equal(tree_shape(box), before, "cancel reverts the changes")
	equal(compound_redo.get_history_count(), 1, "cancel registers nothing")

	run("undoredo --compound Outer", "", ctx)
	run("undoredo --compound Inner", "", ctx)
	run(add_icons, "", ctx)
	run("undoredo commit", "", ctx)
	check(ctx.get_undo_session().is_open(), "inner commit keeps the compound open")
	run("undoredo commit", "", ctx)
	check(compound_redo.get_history_count() == 1 and compound_redo.get_current_action_name() == "Outer", "nested compound is one entry named by the outermost")
	compound_redo.undo()
	equal(tree_shape(box), before, "nested compound undoes as one")

	ctx.host_data["undo_redo"] = func(): return null
	run("undoredo --compound", "", ctx)
	run(add_icons, "", ctx)
	check(run("undoredo commit", "", ctx).stdout.contains("without undo") and tree_shape(box) == after, "compound without an undo object stays applied")
	compound_redo.free()
	main.queue_free()


func tree_shape(node:Node) -> String:
	var parts := PackedStringArray()
	for child in node.get_children():
		parts.append(str(child.name) + ("(%s)" % tree_shape(child) if child.get_child_count() > 0 else ""))
	return ",".join(parts)
