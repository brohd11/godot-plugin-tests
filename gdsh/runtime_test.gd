extends SceneTree

const Sh = preload("res://addons/addon_lib/gdsh/gdsh.gd")
const Utils = preload("res://addons/addon_lib/gdsh/internal/utils.gd")
const FIXTURES = "res://tests/gdsh/fixtures/"
const COMMANDS = FIXTURES + "commands/"
const OVERRIDES = FIXTURES + "overrides/"
var checks = 0
var failures = 0


class InputProbe extends Node:
	var events:Array[InputEvent] = []

	func _unhandled_input(event:InputEvent) -> void:
		events.append(event)


class FixedCompletion extends Sh.Completion:
	var choices:Dictionary

	func get_completions() -> Dictionary:
		_parse()
		return choices


func _initialize():
	_run_tests.call_deferred()


func _run_tests():
	_test_utils()
	_test_execution()
	_test_grammar()
	_test_redirection()
	_test_syntax_errors()
	_test_loading()
	_test_fresh_user_commands()
	_test_builtins()
	_test_files()
	_test_completion()
	_test_structured_completion()
	_test_hidden_scopes()
	_test_host_extensions()
	_test_highlighting()
	_test_echo_formatting()
	_test_script_highlighter_logic()
	await _test_console()
	await _test_console_path_completion()
	print("GDSh: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func check(condition:bool, label:String):
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + label)

func equal(actual, expected, label:String):
	check(actual == expected, "%s (expected %s, got %s)" % [label, str(expected), str(actual)])

func session():
	var ctx = Sh.Context.new()
	ctx.scopes.merge(Sh.Load.load_directory(COMMANDS), true)
	return ctx

func run_text(text:String, ctx:Sh.Context=null):
	if ctx == null:
		ctx = session()
	return Sh.Execute.execute_command_multiline(text, ctx)

func output(text:String):
	return run_text(text).stdout.strip_edges()

func _test_utils():
	for sample in [
		["plain", "plain", false],
		["", "", false],
		["'two words'", "two words", true],
		['"two words"', "two words", true],
		['&"named"', "named", true],
		["&'named'", "named", true],
		['r"raw"', 'r"raw"', true],
		['"unfinished', '"unfinished', false],
		["&plain", "&plain", false],
	]:
		equal(Utils.unquote(sample[0]), sample[1], "local unquote: " + sample[0])
		equal(Utils.is_string_or_string_name(sample[0]), sample[2], "local string detection: " + sample[0])
	var commands = {"default": {}, "late": {&"priority": 2000}, "early": {&"priority": 1}}
	var sorted = Utils.sort_dict_with_priority_key(commands, &"priority")
	equal(sorted.keys(), ["early", "default", "late"], "local priority sort includes default priority")
	equal(commands.keys(), ["default", "late", "early"], "priority sort preserves input order")
	equal(sorted["early"], commands["early"], "priority sort preserves metadata")
	equal(Utils.sort_dict_with_priority_key({}, &"priority"), {}, "empty priority sort")
	var classes = Utils.get_all_global_class_paths()
	equal(classes.size(), ProjectSettings.get_global_class_list().size(), "local class enumeration includes every registered class")
	for entry in ProjectSettings.get_global_class_list():
		equal(classes.get(entry["class"]), entry["path"], "local class enumeration path: " + entry["class"])
	classes.clear()
	check(Utils.get_all_global_class_paths().has("GDSh"), "class enumeration returns a fresh dictionary")
	check(complete("probe --class=").has("Node"), "class completion includes native classes")
	check(complete("probe --class=").has("GDSh"), "class completion includes registered classes")
	var user_classes = complete("probe --user-class=")
	check(user_classes.has("GDSh") and not user_classes.has("Node"), "user class completion uses local enumeration")

func _test_execution():
	equal(output("echo hello"), "hello", "echo")
	equal(output("echo 'one two' \"three four\""), "one two three four", "quoting")
	equal(output("X = world; echo $X"), "world", "assignment")
	equal(output("X = world; echo '$X'"), "$X", "single quotes are literal")
	equal(output("alias @hello = echo hello; @hello"), "hello", "alias")
	equal(output("echo $(echo nested)"), "nested", "substitution")
	equal(output("echo $(echo $(echo deep))"), "deep", "nested substitution")
	equal(output("echo before; echo after # comment"), "before\nafter", "statements/comments")
	equal(output("if true { echo yes } else { echo no }"), "yes", "conditional")
	equal(output("if false { echo no } elif true { echo yes } else { echo no }"), "yes", "elif")
	equal(output("for item in a b c { echo $item }"), "a\nb\nc", "for loop")
	equal(output("for item in a b c { echo $item; break }"), "a", "break")
	equal(output("for item in a b { echo $item; continue; echo no }"), "a\nb", "continue")
	equal(output("while true { echo once; break }"), "once", "while")
	equal(output("greet() { echo $0 $1 $#; shift; echo $1; return 1; echo no }; greet a b; echo $?"), "greet a 2\nb\n1", "function arguments, shift and return")
	equal(output("X = outer; f() { local X = inner; echo $X }; f; echo $X"), "inner\nouter", "local variable")
	equal(output("X = outer; f() { X = inner }; f; echo $X"), "inner", "variable propagation")
	equal(output("false && echo no || echo yes"), "yes", "failure short circuit")
	equal(output("true || echo no && echo yes"), "yes", "success short circuit")
	equal(output("[ a == a ] && echo same"), "same", "comparison")
	equal(output("a != b && echo different"), "different", "implicit comparison")
	equal(output("expr 1 + 2"), "3", "expression")
	check(not run_text('expr "Engine.get_version_info()"').stdout.is_empty(), "runtime singleton expression")
	var piped = run_text("echo first | sink")
	equal(piped.stdout.strip_edges(), "stdin:first", "stdin pipe")
	equal(piped.stderr.strip_edges(), "sink diagnostic", "stderr separate from stdout")
	equal(output("probe --mode=fast --loud one -- two three"), "fast:true:one:two,three", "flags and payload")
	var error = run_text("does_not_exist")
	equal(error.exit_code, Sh.Context.ExitCode.ERR, "unknown command status")
	check(error.stderr.contains("Unrecognized command"), "unknown command diagnostic")
	var exit_ctx = run_text("echo first; exit 7; echo no")
	equal(exit_ctx.stdout.strip_edges(), "first", "exit stops execution")
	equal(exit_ctx.exit_code, 7, "exit preserves requested status")
	equal(output("(exit 7); echo alive"), "alive", "subshell exit isolation")
	var a = Sh.Context.new()
	var b = Sh.Context.new()
	run_text("X = one", a)
	check(not b.variables.has("$X"), "independent variables")
	a.scopes_hidden.erase("echo")
	check(b.scopes_hidden.has("echo"), "independent builtin scopes")
	equal(Sh.Execute.execute_command(" ").exit_requested, false, "blank command is harmless")
	equal(run_text("false").exit_code, 1, "false status")
	equal(run_text("break").exit_code, 2, "break outside loop")
	equal(run_text("return").exit_code, 2, "return outside function")
	check(run_text("echo --help").stdout.contains("Echos"), "per-command help")

func _test_loading():
	var scopes = Sh.Load.load_directory(COMMANDS)
	equal(scopes.size(), 4, "loose and directory commands")
	check(scopes.has("door") and not scopes.has("open"), "children remain nested")
	equal(output("door open north"), "opened:north", "nested command execution")
	var script = Sh.Load.load_command(COMMANDS + "probe.gd")
	check(script != null, "single command loading")
	var custom = Sh.Context.new("", false)
	custom.scopes[script.get_command_name()] = {"script": script}
	equal(run_text("probe", custom).stdout.strip_edges(), "default:false::", "manual registration")
	var builtins = Sh.Load.load_builtins()
	equal(builtins.size(), 16, "builtin manifest includes parent")
	check(builtins.has("help"), "help is a builtin")
	for name in ["os", "clear", "global", "cat", "pwd"]:
		check(not builtins.has(name), "excluded command: " + name)
	print("Expected loader diagnostics follow:")
	check(Sh.Load.load_command(FIXTURES + "missing.gd") == null, "missing command")
	check(Sh.Load.load_command(FIXTURES + "invalid/not_command.gd") == null, "invalid command base")
	var duplicates = Sh.Load.load_directory(FIXTURES + "duplicates/")
	equal(duplicates.size(), 1, "duplicates reported and skipped")
	equal(duplicates.duplicate.script.resource_path, FIXTURES + "duplicates/a.gd", "deterministic first registration")

func _test_builtins():
	var ctx = Sh.Context.new()
	check(ctx.scopes_hidden.has("builtins") and ctx.scopes.is_empty(), "builtin parent is hidden")
	for text in ["", "bui"]:
		var choices = complete(text, ctx)
		check(not choices.has("builtins") and not choices.has("echo"), "builtins omitted from root completion: " + text)
	var public_names = ["break", "continue", "return", "exit", "shift", "true", "false", "[", "expr", "echo", "source", "cd", "help"]
	var choices = complete("builtins ", ctx)
	var children = ctx.get_scope("builtins").script.new().get_commands()
	equal(children.size(), public_names.size(), "parent discovers only public builtins")
	for name in public_names:
		check(children.has(name) and choices.has(name), "builtin child routing and completion: " + name)
	for name in ["__function__", "__run_script__"]:
		check(ctx.scopes_hidden.has(name) and not choices.has(name), "internal builtin remains registered but is not suggested: " + name)
	check(complete("builtins ec", ctx).has("echo"), "partial builtin child completion")
	ctx.cwd = COMMANDS
	check(complete("builtins cd ", ctx).has("door"), "builtin child delegates directory completion")

	var listing = run_text("builtins")
	equal(listing.exit_code, 0, "bare builtins succeeds")
	check(listing.stdout.contains("Subcommands:"), "bare builtins lists children")
	for name in public_names:
		check((listing.stdout + "\n").contains("\n  " + name + "\n"), "builtin listing includes: " + name)
	check(not listing.stdout.contains("__function__") and not listing.stdout.contains("__run_script__"), "builtin help omits internals")
	equal(run_text("builtins --help").stdout, listing.stdout, "explicit parent help matches listing")
	equal(run_text("builtins echo --help").stdout, run_text("echo --help").stdout, "namespaced child help")
	check(run_text("help").stdout.contains("\n  builtins\n"), "help lists hidden parent")
	equal(run_text("builtins unknown").exit_code, 1, "invalid builtin child fails")
	equal(output("builtins echo hello"), "hello", "namespaced echo")
	equal(output("builtins echo first | sink"), "stdin:first", "namespaced pipeline")
	equal(run_text("builtins true").exit_code, 0, "namespaced true status")
	equal(run_text("builtins false").exit_code, 1, "namespaced false status")
	equal(run_text("builtins [ a == a ]").exit_code, 0, "namespaced comparison succeeds")
	equal(run_text("builtins [ a == b ]").exit_code, 1, "namespaced comparison fails")
	equal(output("for item in a b { builtins echo $item; builtins break }"), "a", "namespaced break")
	equal(output("for item in a b { builtins echo $item; builtins continue; echo no }"), "a\nb", "namespaced continue")
	equal(output("f(){ builtins shift; echo $1; builtins return 3; echo no }; f a b; echo $?"), "b\n3", "namespaced shift and return")
	var exited = run_text("builtins exit 7; echo no")
	equal(exited.exit_code, 7, "namespaced exit status")
	check(exited.stdout.is_empty(), "namespaced exit stops execution")
	run_text("builtins cd door", ctx)
	equal(ctx.cwd, COMMANDS.path_join("door"), "namespaced cd propagates cwd")
	equal(output("builtins source tests/gdsh/fixtures/hello.gdsh"), "resource script", "namespaced source")

	ctx = Sh.Context.new()
	ctx.load(OVERRIDES)
	equal(run_text("echo hi", ctx).stdout.strip_edges(), "layered:hi", "root builtin override executes")
	ctx.stdout = ""
	equal(run_text("builtins echo hi", ctx).stdout.strip_edges(), "hi", "namespaced builtin bypasses root override")
	var independent = Sh.Context.new()
	ctx.scopes_hidden.erase("builtins")
	check(independent.has_scope("builtins"), "independent builtin parent registration")
	var child = Sh.Context.new_ctx("child", independent)
	child.scopes_hidden.erase("builtins")
	check(independent.has_scope("builtins"), "child parent registration is independent")
	var empty = Sh.Context.new("", false)
	check(empty.scopes.is_empty() and empty.scopes_hidden.is_empty(), "context without builtins has no registrations")

func _write(path:String, text:String):
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)

func _read(path:String) -> String:
	return FileAccess.get_file_as_string(path)

func _test_files():
	equal(Sh.Context.new().cwd, "res://", "default resource working directory")
	equal(output("source tests/gdsh/fixtures/hello.gdsh"), "resource script", "source from resource cwd")
	var temp = "user://gdsh_test_%s" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(temp.path_join("child"))
	_write(temp.path_join("source.gdsh"), "#!gdsh\nX = sourced; echo sourced")
	_write(temp.path_join("args.gdsh"), "#!gdsh\nX = child; echo $1 $#; exit 6")
	_write(temp.path_join("not_gdsh.txt"), "echo no")
	var ctx = session()
	ctx.cwd = ProjectSettings.globalize_path(temp)
	run_text("source source.gdsh; echo $X", ctx)
	equal(ctx.stdout.strip_edges(), "sourced\nsourced", "source state propagation")
	ctx.stdout = ""
	run_text('"' + ctx.cwd.path_join("args.gdsh") + '" value; echo $? $X', ctx)
	equal(ctx.stdout.strip_edges(), "value 1\n6 sourced", "script arguments, status, and state isolation")
	run_text("cd child", ctx)
	check(ctx.cwd.ends_with("/child"), "relative cd propagates")
	var before = ctx.cwd
	run_text("cd missing", ctx)
	equal(ctx.cwd, before, "failed cd preserves cwd")
	equal(ctx.exit_code, 2, "failed cd status")
	check(not Sh.Execute.source_file(temp.path_join("missing.gdsh")).stderr.is_empty(), "missing source diagnostic")
	equal(Sh.Execute.source_file(temp.path_join("not_gdsh.txt")).exit_code, 1, "non-gdsh rejected")
	for name in ["source.gdsh", "args.gdsh", "not_gdsh.txt"]:
		DirAccess.remove_absolute(temp.path_join(name))
	DirAccess.remove_absolute(temp.path_join("child"))
	DirAccess.remove_absolute(temp)

func _write_file(path:String, text:String) -> void:
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _test_fresh_user_commands():
	var directory = "user://gdsh_fresh_command_test"
	DirAccess.make_dir_recursive_absolute(directory)
	var path = directory.path_join("fresh.gd")
	var source = 'extends "res://addons/addon_lib/gdsh/command_base.gd"\n' \
			+ 'static func get_command_name(): return "fresh"\n' \
			+ 'static func get_self_command_data(): return _command_data({&"help": "fresh"})\n' \
			+ 'func _execute(ctx): ctx.append_output("%s")\n'
	_write_file(path, source % "first")
	var ctx = session()
	var script = Sh.Load.load_command(path)
	ctx.scopes["fresh"] = {"script": script}
	equal(run_text("fresh", Sh.Context.new_ctx("fresh", ctx)).stdout.strip_edges(), "first", "user command runs")
	_write_file(path, source % "second")
	equal(run_text("fresh", Sh.Context.new_ctx("fresh", ctx)).stdout.strip_edges(), "second", "commands outside res:// reload on use")
	check(Sh.Load.fresh(script).new() is Sh.CommandBase, "reloaded user command keeps the shared base class")
	check(Sh.Load.fresh(Sh.Load.load_command(COMMANDS + "probe.gd")) == Sh.Load.load_command(COMMANDS + "probe.gd"), "res:// commands stay cached")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(directory)

func _test_echo_formatting():
	var ctx = session()
	ctx.variables["$NAME"] = "world"
	ctx.aliases["@d"] = "door open"
	var syntax = Sh.Console.Highlighter.new()
	syntax.set_context(ctx)
	var plain = syntax.to_bbcode("probe [x]")
	check(plain.contains("[color=%s]probe[/color]" % syntax.palette.scope.to_html(false)), "echo colors command scopes")
	check(plain.contains("[lb]x]") and not plain.contains("[x]"), "echo escapes BBCode in the command")
	var tags = RegEx.create_from_string("\\[/?color[^\\]]*\\]")
	var shown = tags.sub(syntax.to_bbcode("echo $NAME $MISSING @d", true), "", true).replace("[lb]", "[")
	equal(shown, "echo [world]$NAME [undef]$MISSING [door open]@d", "echo previews variable and alias values")
	equal(tags.sub(syntax.to_bbcode("echo $NAME"), "", true), "echo $NAME", "echo previews are optional")
	var counter = Sh.Load.load_command(COMMANDS + "counter.gd")
	counter.calls = 0
	ctx.variables["$SUB"] = "$(counter)"
	syntax.to_bbcode("echo $(counter) $SUB", true)
	equal(counter.calls, 0, "echo previews never evaluate substitutions")

func complete(text:String, ctx:Sh.Context=null, caret:int=-1):
	if ctx == null:
		ctx = session()
	return Sh.Completion.new(text, ctx, caret).get_completions()

func _test_completion():
	check(complete("").has("probe"), "visible root suggestions")
	check(not complete("").has("echo"), "hidden builtins omitted from root suggestions")
	check(complete("door ").has("open"), "child suggestions")
	check(complete("door open ").has("north"), "child completion hook")
	check(complete("door open north trailing", null, 10).has("north"), "caret before trailing text")
	check(complete("echo ignored | door ").has("open"), "pipeline completion")
	check(complete("false && door ").has("open"), "logical completion")
	check(complete("echo \"x | y\"; door ").has("open"), "quoted separator completion")
	check(complete("probe --mode=fast one ").has("route:fast:1:-1:one"), "routed flag and positional index")
	check(complete("probe -- payload ").has("route:default:-1:1:"), "payload index")
	check(complete("probe --mo").has("--mode="), "partial flag completion")
	var ctx = session()
	ctx.variables["$TARGET"] = "door"
	ctx.aliases["@d"] = "door"
	check(complete("$TARGET ", ctx).has("open"), "variable routing")
	check(complete("@d ", ctx).has("open"), "alias routing")
	check(complete("echo $T", ctx).has("$TARGET"), "variable suggestions")
	check(complete("@", ctx).has("@d = [door]"), "alias suggestions show their source")
	equal(complete("@", ctx)["@d = [door]"][Sh.Options.Keys.METADATA][Sh.Options.Keys.INSERT], "@d", "alias suggestion inserts the name")
	ctx.functions["greet"] = "echo hi"
	check(complete("", ctx).has("greet[func]"), "function suggestions are tagged")
	ctx.functions.erase("greet")
	ctx.cwd = COMMANDS
	check(complete("cd ", ctx).has("door"), "directory suggestions")
	check(complete("probe --file=", ctx).has(COMMANDS + "probe.gd"), "file flag suggestions")
	check(complete("probe --dir=", ctx).has(COMMANDS + "door"), "directory flag suggestions")
	var counter = Sh.Load.load_command(COMMANDS + "counter.gd")
	counter.calls = 0
	ctx.variables["$INDIRECT"] = "$(counter)"
	ctx.aliases["@side"] = "echo $(counter)"
	ctx.stdout = "preserved output"
	ctx.stderr = "preserved error"
	ctx.last_status = 7
	var saved_vars = ctx.variables.duplicate(true)
	for input in ["echo $(counter)", "echo $(echo $(counter))", 'echo "$(counter)"', "echo $INDIRECT", "@side", "probe -- $(counter)"]:
		complete(input, ctx)
	equal(counter.calls, 0, "completion never executes direct/nested/indirect/payload substitutions")
	equal(ctx.variables, saved_vars, "completion preserves variables")
	equal(ctx.stdout, "preserved output", "completion preserves stdout")
	equal(ctx.stderr, "preserved error", "completion preserves stderr")
	equal(ctx.last_status, 7, "completion preserves status")
	run_text("echo $(counter)", ctx)
	equal(counter.calls, 1, "execution still evaluates substitutions once")
	var request = Sh.Completion.new("door ", ctx)
	request.get_completions()
	check(request.get_completions().has("open"), "completion request can be reused")

func _test_grammar():
	var cases = [
		['echo first;if [ someval == "" ]{echo yes}else{echo fail}', "first\nfail"],
		['echo first;if [ "" == "" ]{echo yes}else{echo fail}', "first\nyes"],
		['f(){if true{echo yes}else{echo no}};f', "yes"],
		['f()\n{echo one;echo two};f', "one\ntwo"],
		['for x in a b{if [ $x == a ]{echo A}else{echo B}}', "A\nB"],
		['false||echo one|sink&&echo two', "stdin:one\ntwo"],
		['true||false&&echo left_associative', "left_associative"],
		['false&&echo no|sink||echo recovered', "recovered"],
		['true||echo no|sink', ""],
		['echo one\\;two \\| \\&\\& \\> \\{ \\} \\( \\)', "one;two | && > { } ( )"],
		['echo "a;|&&{}()>discard"', "a;|&&{}()>discard"],
		['echo before#literal #comment\necho after', "before#literal\nafter"],
		['echo one\\\ntwo', "onetwo"],
		['echo {a:1} prefix{nested:{x:2}}suffix', "{a:1} prefix{nested:{x:2}}suffix"],
		['probe "" end', "default:false:,end:"],
		['probe "--loud" "--"', "default:false:--loud,--:"],
		['probe --mode="two words"', "two words:false::"],
		['probe --mode="\'quoted\'"', "'quoted':false::"],
		['probe pre"two words"post', "default:false:pretwo wordspost:"],
		['probe "$(echo one two)"', "default:false:one two:"],
		['probe a$(echo one two)b', "default:false:aone,twob:"],
		['echo $(if true{echo $(echo nested)})', "nested"],
		['X="two words";echo $X', "two words"],
		['X=one&&echo $X', "one"],
		['X = {a:1};echo $X', "{a:1}"],
		['X=one  two;echo $X', "one  two"],
		['X=outer;(X=inner;echo $X);echo $X', "inner\nouter"],
		['f(){for x in a b{if true{return 4};echo no};echo no};f;echo $?', "4"],
		['for x in a b{for y in 1 2{echo $x$y;break};echo end}', "a1\nend\nb1\nend"],
		['X=yes;while [ $X == yes ]{X=no;true};echo $?', "0"],
		['alias @p = echo hello|sink;@p', "stdin:hello"],
		['alias @p = false||echo recovered;@p', "recovered"],
	]
	for pair in cases:
		equal(output(pair[0]), pair[1], "grammar: " + pair[0])
	equal(output("true&&".repeat(1000) + "echo done"), "done", "long logical chain is iterative")
	equal(run_text("if ".repeat(150) + "true{}").exit_code, 2, "excessive command nesting is rejected")
	equal(run_text("while true{echo loop;continue;echo no}").stdout.count("loop\n"), 100, "while loop iteration limit and continue")
	var ctx = session()
	var counter = Sh.Load.load_command(COMMANDS + "counter.gd")
	counter.calls = 0
	for text in ['false&&echo $(counter)', 'true||echo $(counter)', 'if false{echo $(counter)}', 'f(){echo $(counter)}', 'false&&X=$(counter)']:
		run_text(text, ctx)
	equal(counter.calls, 0, "unselected nodes never expand substitutions")
	run_text('f', ctx)
	equal(counter.calls, 1, "function substitution runs when called")
	ctx.variables["$DATA"] = ";counter|sink >discard"
	ctx.stdout = ""
	run_text('echo $DATA', ctx)
	equal(ctx.stdout.strip_edges(), ";counter|sink >discard", "expanded data cannot inject operators")
	equal(counter.calls, 1, "expanded syntax remains data")
	ctx.functions["f"] = "echo changed"
	ctx.stdout = ""
	run_text("f", ctx)
	equal(ctx.stdout.strip_edges(), "changed", "function cache invalidated by direct source update")
	ctx.aliases["@a"] = "@b"
	ctx.aliases["@b"] = "@a"
	equal(run_text("@a", ctx).exit_code, 2, "alias cycle is reported")
	ctx.stdout = ""
	run_text("echo alive", ctx)
	equal(ctx.stdout.strip_edges(), "alive", "alias error does not stop session")

func _test_redirection():
	var cases = [
		["sink >discard", "", "sink diagnostic", 0],
		["sink 1>/dev/null", "", "sink diagnostic", 0],
		["sink 2>discard", "stdin:", "", 0],
		["sink &>discard", "", "", 0],
		["sink >discard 2>/dev/null", "", "", 0],
		["2>discard sink", "stdin:", "", 0],
		["sink 2 >discard", "", "", 1], # argument count diagnostic survives stdout discard
		["echo one>discard|sink", "stdin:", "sink diagnostic", 0],
		["echo one|sink>discard", "", "sink diagnostic", 0],
		["echo one|sink 2>discard", "stdin:one", "", 0],
		["unknown_command 2>discard||echo recovered", "recovered", "", 0],
		["unknown_command 2>discard&&echo no", "", "", 2],
		["false >discard||echo recovered", "recovered", "", 0],
		["true >discard&&echo yes", "yes", "", 0],
		["if true{sink}&>discard;echo alive", "alive", "", 0],
		["for x in a b{sink}2>discard", "stdin:\nstdin:", "", 0],
		["while true{sink;break}>discard", "", "sink diagnostic", 0],
		["(sink)2>discard", "stdin:", "", 0],
		["f(){sink;return 4};f &>discard", "", "", 4],
		["f(){echo before;g(){sink};g;echo after};f>discard", "", "sink diagnostic", 0],
		["X=before;if true{X=after;echo no}>discard;echo $X", "after", "", 0],
		["X=before;for x in a{X=after;echo no}>discard;echo $X", "after", "", 0],
		["X=before;f(){X=after;echo no};f>discard;echo $X", "after", "", 0],
		["echo before;sink&>discard;echo after", "before\nafter", "", 0],
		["probe before 2>discard after", "default:false:before,after:", "", 0],
		["probe '2>discard'", "default:false:2>discard:", "", 0],
		["echo $(sink) 2>discard", "stdin:", "", 0],
		["echo one|false", "", "", 1],
		["false|true", "", "", 0],
	]
	for row in cases:
		var ctx = run_text(row[0])
		equal(ctx.stdout.strip_edges(), row[1], "redirect stdout: " + row[0])
		if row[0] == "sink 2 >discard":
			check(not ctx.stderr.is_empty(), "spaced descriptor remains argument")
		else:
			equal(ctx.stderr.strip_edges(), row[2], "redirect stderr: " + row[0])
		equal(ctx.exit_code, row[3], "redirect status: " + row[0])

	var temp = "user://gdsh_redirect_%s" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(temp)
	var ctx = session()
	ctx.cwd = temp
	run_text("echo first >output.txt", ctx)
	equal(ctx.stdout, "", "file redirect removes stdout")
	equal(_read(temp.path_join("output.txt")), "first\n", "stdout overwrite creates file")
	run_text("echo second 1>output.txt", ctx)
	equal(_read(temp.path_join("output.txt")), "second\n", "descriptor stdout overwrites file")
	run_text("echo third >>output.txt", ctx)
	equal(_read(temp.path_join("output.txt")), "second\nthird\n", "stdout append")
	run_text("echo fourth 1>>output.txt", ctx)
	equal(_read(temp.path_join("output.txt")), "second\nthird\nfourth\n", "descriptor stdout append")
	_write(temp.path_join("earlier.txt"), "old")
	run_text("echo final >earlier.txt >last.txt", ctx)
	equal(_read(temp.path_join("earlier.txt")), "", "earlier redirect is still truncated")
	equal(_read(temp.path_join("last.txt")), "final\n", "last stdout redirect wins")
	ctx.stdout = ""
	run_text("echo piped >piped.txt | sink", ctx)
	equal(ctx.stdout.strip_edges(), "stdin:", "file stdout overrides pipeline destination")
	equal(_read(temp.path_join("piped.txt")), "piped\n", "redirected pipeline stage writes file")

	ctx.stdout = ""
	ctx.stderr = ""
	run_text("sink >stdout.txt 2>stderr.txt", ctx)
	equal(ctx.stdout, "", "separate stdout file removes output")
	equal(ctx.stderr, "", "separate stderr file removes diagnostic")
	equal(_read(temp.path_join("stdout.txt")), "stdin:\n", "stdout file contents")
	equal(_read(temp.path_join("stderr.txt")), "sink diagnostic\n", "stderr file contents")
	run_text("sink 2>>stderr.txt", ctx)
	equal(ctx.stdout.strip_edges(), "stdin:", "stderr append preserves stdout")
	equal(_read(temp.path_join("stderr.txt")), "sink diagnostic\nsink diagnostic\n", "stderr append")

	ctx.stdout = ""
	ctx.stderr = ""
	run_text("sink &>both.txt", ctx)
	equal(_read(temp.path_join("both.txt")), "stdin:\nsink diagnostic\n", "combined redirect writes stdout then stderr")
	run_text("sink &>>both.txt", ctx)
	equal(_read(temp.path_join("both.txt")), "stdin:\nsink diagnostic\nstdin:\nsink diagnostic\n", "combined append")

	_write(temp.path_join("input.txt"), "one\ntwo\n")
	ctx.stdout = ""
	ctx.stderr = ""
	run_text("0<input.txt sink", ctx)
	equal(ctx.stdout, "stdin:one\ntwo\n", "file input feeds stdin exactly")
	ctx.stdout = ""
	run_text("echo piped | sink <input.txt", ctx)
	equal(ctx.stdout, "stdin:one\ntwo\n", "file input overrides pipeline input")
	ctx.stdout = ""
	run_text("sink <discard", ctx)
	equal(ctx.stdout.strip_edges(), "stdin:", "discard supplies empty stdin")

	ctx.stdout = ""
	ctx.stderr = ""
	ctx.variables["$OUT"] = "space name.txt"
	run_text('echo spaced >"$OUT"', ctx)
	equal(_read(temp.path_join("space name.txt")), "spaced\n", "quoted variable target")
	run_text("echo dynamic >$(echo generated.txt)", ctx)
	equal(_read(temp.path_join("generated.txt")), "dynamic\n", "substitution target")
	var expanded_error = run_text("echo hidden >$(echo one two)", ctx)
	equal(expanded_error.exit_code, 1, "multi-field target fails")
	check(expanded_error.stderr.contains("exactly one non-empty path"), "multi-field target diagnostic")

	var counter = Sh.Load.load_command(COMMANDS + "counter.gd")
	counter.calls = 0
	ctx.stdout = ""
	ctx.stderr = ""
	run_text("counter >missing/out.txt", ctx)
	equal(counter.calls, 0, "output open failure skips command")
	equal(ctx.exit_code, 1, "output open failure status")
	check(ctx.stderr.contains("cannot open"), "output open failure diagnostic")
	run_text("counter <missing.txt", ctx)
	equal(counter.calls, 0, "input open failure skips command")

	for name in ["output.txt", "earlier.txt", "last.txt", "piped.txt", "stdout.txt", "stderr.txt", "both.txt", "input.txt", "space name.txt", "generated.txt"]:
		DirAccess.remove_absolute(temp.path_join(name))
	DirAccess.remove_absolute(temp)

func _test_syntax_errors():
	var counter = Sh.Load.load_command(COMMANDS + "counter.gd")
	for invalid in ['echo "unclosed', "echo 'unclosed", "echo \\", "echo $(echo unclosed", "echo $(true&&)", 'f(){echo missing', 'if true{echo missing', 'for x in a{echo missing', '(echo missing', 'echo literal{missing', 'echo hi}', 'echo hi)', 'echo hi|', 'echo hi&&', 'echo hi||', '||echo hi', 'else{echo no}', 'f(){echo hi}>discard', 'echo hi >', 'echo hi &>>', 'echo hi 3>discard', 'echo hi 0>discard', 'echo hi 1<discard', 'echo hi 2<discard', 'echo hi 2>&1', 'echo hi <<file', 'echo hi &', 'echo hi |& sink', 'X=$(true&&)', 'X=one &', 'X=one |& sink']:
		counter.calls = 0
		var ctx = session()
		run_text("counter;\n" + invalid, ctx)
		equal(counter.calls, 0, "syntax error prevents partial execution: " + invalid)
		equal(ctx.exit_code, 2, "syntax error status: " + invalid)
		check(ctx.stderr.contains("syntax error at 2:"), "syntax error location: " + invalid)
		check(not ctx.exit_requested, "syntax error is recoverable: " + invalid)
		ctx.stdout = ""
		run_text("echo alive", ctx)
		equal(ctx.stdout.strip_edges(), "alive", "session recovers: " + invalid)

func _test_structured_completion():
	for text in ["if true{door ", "if true{echo yes}else{door ", "f(){door ", "for x in a{door ", "(door ", "echo $(door ", "echo $(echo $(door ", 'echo "$(door ', "echo hi&&door ", "echo hi||door ", "echo hi|door "]:
		check(complete(text).has("open"), "structured completion: " + text)
	for text in ["sink >", "sink 2>", "sink &>dis", "if true{sink}> ", "(sink)2>/dev/"]:
		var options = complete(text)
		check(options.has("discard") and options.has("/dev/null"), "discard completion: " + text)
		check(not options.has("echo"), "redirect target excludes commands: " + text)
	check(complete("sink <tests/gdsh/fixtures/he").has("tests/gdsh/fixtures/hello.gdsh"), "input file completion")
	check(complete("sink >tests/gdsh/fixtures/").has("tests/gdsh/fixtures/hello.gdsh"), "output file completion")
	check(complete("probe 2>discard --mo").has("--mode="), "flags after a redirection")
	check(complete("probe --mode=\"two words\" one ").has("route:two words:1:-1:one"), "quoted flag value completion")
	check(complete("probe 'unfinished").has("route:default:0:-1:unfinished"), "unfinished quote completion")


func _test_hidden_scopes():
	var ctx = Sh.Context.new()
	check(ctx.scopes.is_empty(), "new context has no visible builtin scopes")
	check(ctx.scopes_hidden.has("echo") and ctx.scopes_hidden.has("help"), "new context stores builtins as hidden scopes")
	check(not Sh.Completion.new("", ctx).get_completions().has("help"), "hidden help omitted from root completion")
	equal(run_text("echo hidden builtin", ctx).stdout.strip_edges(), "hidden builtin", "hidden builtin executes normally")

	ctx.stdout = ""
	var initial_help = run_text("help", ctx).stdout.strip_edges()
	check(initial_help.begins_with("Commands:\n  (none)\n\nHidden commands:"), "help separates empty visible and hidden scopes")
	check(initial_help.contains("\n  help"), "help lists itself as hidden")
	check(not initial_help.contains("__function__") and not initial_help.contains("__run_script__"), "help excludes reserved internal scopes")
	var hidden_lines = initial_help.get_slice("Hidden commands:\n", 1).split("\n", false)
	var sorted_hidden = Array(hidden_lines)
	sorted_hidden.sort()
	equal(Array(hidden_lines), sorted_hidden, "help sorts hidden commands")

	ctx.cwd = FIXTURES
	var visible = ctx.load("commands/probe.gd")
	check(visible.has("probe") and ctx.scopes.has("probe"), "context loads a relative command file as visible")
	check(not ctx.scopes_hidden.has("probe"), "visible command is absent from hidden scopes")
	ctx.load("commands/probe.gd", true)
	check(ctx.scopes_hidden.has("probe") and not ctx.scopes.has("probe"), "newest load moves a command to hidden scopes")
	check(not Sh.Completion.new("", ctx).get_completions().has("probe"), "hidden loaded command omitted from root completion")
	check(Sh.Completion.new("probe --mo", ctx).get_completions().has("--mode="), "typed hidden command retains flag completion")
	ctx.stdout = ""
	equal(run_text("probe", ctx).stdout.strip_edges(), "default:false::", "hidden loaded command executes")

	ctx.load("commands", false)
	check(ctx.scopes.has("door") and not ctx.scopes_hidden.has("door"), "visible directory load registers visible scopes")
	check(Sh.Completion.new("door ", ctx).get_completions().has("open"), "visible command retains child completion")
	ctx.load("commands", true)
	check(ctx.scopes_hidden.has("door") and not ctx.scopes.has("door"), "hidden directory load moves prior visible scopes")
	check(Sh.Completion.new("door ", ctx).get_completions().has("open"), "typed hidden command retains child completion")

	var child = Sh.Context.new_ctx("child", ctx)
	check(child.scopes.has("probe") == ctx.scopes.has("probe"), "child copies visible scopes")
	check(child.scopes_hidden.has("door"), "child copies hidden scopes")
	child.scopes_hidden.erase("door")
	check(ctx.scopes_hidden.has("door"), "child hidden scope dictionary is independent")
	ctx.scopes["echo"] = {"visible": true}
	equal(ctx.get_scope("echo"), {"visible": true}, "visible dictionary wins a direct duplicate")
	ctx.scopes["__private_test__"] = {}
	var layered_help = run_text("help", ctx).stdout
	check(layered_help.contains("Commands:\n  echo"), "help lists visible commands")
	check(not layered_help.contains("__private_test__"), "help filters visible reserved scopes")
	equal(run_text("help extra", ctx).exit_code, 1, "help accepts no positional arguments")


func _highlight_color(edit:CodeEdit, column:int, line:int=0) -> Color:
	var spans = edit.syntax_highlighter.get_line_syntax_highlighting(line)
	var color = Color.TRANSPARENT
	for start in spans:
		if start > column:
			break
		color = spans[start].color
	return color


func _check_highlight(edit:CodeEdit, text:String, fragment:String, color:Color, label:String):
	edit.text = text
	var start = text.find(fragment)
	check(start >= 0, label + " has sample fragment")
	for column in range(start, start + fragment.length()):
		equal(_highlight_color(edit, column), color, label + " column " + str(column))


func _test_highlighting():
	var palette = Sh.Console.Palette.new({"scope": Color.RED, &"variable": Color.GREEN})
	equal(palette.scope, Color.RED, "palette constructor overrides a string key")
	equal(palette.variable, Color.GREEN, "palette constructor overrides a StringName key")
	equal(palette.text, Sh.Console.Palette.new().text, "palette retains unspecified defaults")
	print("Expected palette diagnostics follow:")
	var invalid = Sh.Console.Palette.new({"missing": Color.RED, "text": 1, "alias": Color.BLUE})
	equal(invalid.text, palette.text, "invalid palette value retains default")
	equal(invalid.alias, Color.BLUE, "valid overrides survive invalid entries")
	var ctx = session()
	ctx.variables["$KNOWN"] = "value"
	ctx.functions["probe"] = "echo function"
	ctx.aliases["@p"] = "probe"
	ctx.set_positional_args("test", ["argument"])
	var syntax = Sh.Console.Highlighter.new()
	syntax.set_context(ctx)
	syntax.set_palette(palette)
	var edit = CodeEdit.new()
	edit.syntax_highlighter = syntax
	root.add_child(edit)
	check(not syntax.highlight_globals, "global highlighting defaults off")
	_check_highlight(edit, "builtins echo hello", "builtins", palette.scope, "hidden parent highlighted")
	_check_highlight(edit, "builtins echo hello", "echo", palette.scope, "hidden command highlighted")
	_check_highlight(edit, "probe arg", "probe", palette.function_def, "function shadows command color")
	_check_highlight(edit, "@p arg", "@p", palette.alias, "context alias highlighted")
	_check_highlight(edit, "echo $KNOWN", "$KNOWN", palette.variable, "known variable")
	_check_highlight(edit, "echo $MISSING", "$MISSING", palette.unknown_variable, "unknown variable")
	for name in ["$0", "$1", "$?", "$#", "$@"]:
		_check_highlight(edit, "echo " + name, name, palette.variable, "special/positional variable " + name)
	_check_highlight(edit, "echo $2", "$2", palette.unknown_variable, "missing positional variable")
	for text in ["echo 'echo $KNOWN >'", 'echo "echo"', "echo \\$KNOWN", "echo \\>", "echo # echo $KNOWN >", "echo echox"]:
		edit.text = text
		for column in range(5, text.length()):
			equal(_highlight_color(edit, column), palette.text, "literal/comment stays plain: " + text)
	_check_highlight(edit, 'echo "value:$KNOWN"', "$KNOWN", palette.variable, "double quote interpolation")
	_check_highlight(edit, 'echo "$(echo $(echo $KNOWN))"', "$KNOWN", palette.variable, "nested substitution variable")
	_check_highlight(edit, 'echo "$(echo $(echo $KNOWN))"', "$(", palette.symbol, "substitution delimiter")
	_check_highlight(edit, "echo $(probe", "probe", palette.function_def, "incomplete substitution")
	_check_highlight(edit, 'echo "$KNOWN', "$KNOWN", palette.variable, "incomplete quote")
	for op in ["<", "0<", ">", "1>", ">>", "1>>", "2>", "2>>", "&>", "&>>", "<<", ">&", "<&"]:
		_check_highlight(edit, "echo hi " + op + "file", op, palette.symbol, "redirection " + op)
	_check_highlight(edit, "echo hi>file", ">", palette.symbol, "adjacent redirection")
	_check_highlight(edit, "echo hi 2 >file", "2", palette.text, "separated descriptor is an argument")
	for op in ["&&", "||", "|", ";", "(", ")", "{", "}"]:
		_check_highlight(edit, "echo" + op + "echo", op, palette.symbol, "adjacent shell operator " + op)
	for op in ["[", "]", "==", "!="]:
		_check_highlight(edit, "echo " + op, op, palette.symbol, "comparison " + op)
	equal(run_text("echo hi <<file").exit_code, Sh.Context.ExitCode.ERR, "highlighted unsupported redirect remains rejected")
	edit.text = "GDSh.Execute"
	equal(_highlight_color(edit, 0), palette.text, "globals plain by default")
	syntax.highlight_globals = true
	equal(_highlight_color(edit, 0), palette.global_class, "globals enabled invalidates cache")
	equal(_highlight_color(edit, 4), palette.text, "global member suffix stays plain")
	syntax.highlight_globals = false
	equal(_highlight_color(edit, 0), palette.text, "globals disabled invalidates cache")
	edit.text = "echo"
	palette.scope = Color.BLUE
	syntax.set_palette(palette)
	equal(_highlight_color(edit, 0), Color.BLUE, "palette replacement invalidates colors")
	check(Sh.Console.Highlighter.new().palette.scope != Color.BLUE, "default palettes are independent")
	syntax.set_context(Sh.Context.new("", false))
	equal(_highlight_color(edit, 0), palette.text, "context replacement invalidates names")
	syntax.set_context(ctx)
	ctx.variables["$KNOWN"] = "$(counter)"
	var counter = Sh.Load.load_command(COMMANDS + "counter.gd")
	counter.calls = 0
	ctx.stdout = "saved output"
	ctx.stderr = "saved error"
	ctx.last_status = 7
	var variables = ctx.variables.duplicate(true)
	_check_highlight(edit, "echo $(counter) $KNOWN @p", "counter", palette.scope, "substitution command highlighted")
	equal(counter.calls, 0, "highlighting never executes substitutions")
	equal(ctx.variables, variables, "highlighting preserves variables")
	equal(ctx.stdout, "saved output", "highlighting preserves stdout")
	equal(ctx.stderr, "saved error", "highlighting preserves stderr")
	equal(ctx.last_status, 7, "highlighting preserves status")
	edit.text = "echo 'literal\necho $KNOWN'\necho $KNOWN"
	equal(_highlight_color(edit, 0, 1), palette.text, "console scanning respects multiline literal state")
	equal(_highlight_color(edit, 0, 2), palette.scope, "console scanning resumes after multiline literal")
	var script_syntax = Sh.Console.ScriptHighlighter.new()
	script_syntax.set_palette(palette)
	edit.syntax_highlighter = script_syntax
	_check_highlight(edit, 'echo "text"', "text", palette.string, "script option colors string literals")
	edit.text = 'echo "first\nsecond"\necho'
	equal(_highlight_color(edit, 0, 1), palette.string, "script option preserves multiline state")
	palette.string = Color.MAGENTA
	script_syntax.set_palette(palette)
	equal(_highlight_color(edit, 0, 1), Color.MAGENTA, "script palette update clears multiline cache")
	edit.queue_free()


func _script_spans(map:Dictionary) -> Array:
	var spans = []
	for column in map:
		spans.append([column, map[column].color.to_html()])
	return spans


func _test_script_highlighter_logic():
	var logic = Sh.Console.ScriptHighlighter.Logic.new()
	equal(logic.get_line_highlighting(0), {}, "unbound script logic returns no spans")
	var palette = Sh.Console.Palette.new()
	var edit = TextEdit.new()
	var baseline = JSON.parse_string(FileAccess.get_file_as_string(FIXTURES + "script_highlighting.txt"))
	for sample in baseline.cases:
		# JSON numbers are floats; highlighting map columns are integers.
		for spans in sample.lines:
			for span in spans:
				span[0] = int(span[0])
		edit.text = sample.source
		logic.setup(edit, palette)
		for line in edit.get_line_count():
			equal(_script_spans(logic.get_line_highlighting(line)), sample.lines[line], "script baseline line %d: %s" % [line, sample.source])
		logic.clear_cache()
		for line in range(edit.get_line_count() - 1, -1, -1):
			equal(_script_spans(logic.get_line_highlighting(line)), sample.lines[line], "out-of-order script baseline line %d: %s" % [line, sample.source])
	edit.text = 'echo "first\nsecond"'
	logic.clear_cache()
	equal(logic.get_line_highlighting(1)[0].color, palette.string, "script logic caches multiline quote state")
	edit.text = "echo first\nsecond"
	logic.clear_cache()
	equal(logic.get_line_highlighting(1)[0].color, palette.function, "script logic cache clear reflects edited previous line")
	var replacement = Sh.Console.Palette.new({"function": Color.RED})
	logic.setup(edit, replacement)
	equal(logic.get_line_highlighting(1)[0].color, Color.RED, "script logic accepts replacement palette directly")
	edit.free()


func _test_console():
	# Give the popup enough vertical room to test both natural resizing and its cap.
	root.size = Vector2i(640, 480)
	var console = Sh.Console.new()
	var selected_syntax = Sh.Console.Highlighter.new()
	console.set_highlighter(selected_syntax)
	root.add_child(console)
	check(console.input.syntax_highlighter == selected_syntax, "pre-tree highlighter selection persists")
	check(selected_syntax.context == console.context, "console binds highlighter context")
	console.input.text = "probe"
	equal(_highlight_color(console.input, 0), selected_syntax.palette.text, "unloaded command is plain")
	console.load(COMMANDS + "probe.gd")
	equal(_highlight_color(console.input, 0), selected_syntax.palette.scope, "loading commands refreshes highlighting")
	console.input.text = "$HIGHLIGHT_TEST"
	equal(_highlight_color(console.input, 0), selected_syntax.palette.unknown_variable, "undefined variable is unknown")
	console.execute("HIGHLIGHT_TEST=value")
	equal(_highlight_color(console.input, 0), selected_syntax.palette.variable, "execution refreshes variable highlighting")
	console.set_context(Sh.Context.new())
	equal(_highlight_color(console.input, 0), selected_syntax.palette.unknown_variable, "console context replacement refreshes highlighting")
	console.clear_history()
	console.input.text = ""
	var script_option = Sh.Console.ScriptHighlighter.new()
	console.set_highlighter(script_option)
	check(console.input.syntax_highlighter == script_option, "console accepts script highlighter")
	console.set_highlighter(SyntaxHighlighter.new())
	check(console.input.syntax_highlighter != selected_syntax, "console accepts native highlighters")
	console.set_highlighter(selected_syntax)
	check(console is VBoxContainer, "console is an instantiable VBoxContainer")
	check(console.prompt_row is HBoxContainer, "console exposes its prompt row")
	check(console.prompt_label is RichTextLabel, "console exposes its prompt label")
	check(console.input is CodeEdit, "console input is a CodeEdit")
	check(console.output == null, "console transcript is optional")
	check(console.get_text_edit() == console.input, "console returns its text edit")
	check(console.get_prompt_label() == console.prompt_label, "console returns its prompt label")
	var default_prompt = "[color=%s]Console $[/color]" % Color.LIGHT_BLUE.to_html()
	equal(console.prompt_label.text, default_prompt, "default console prompt is light blue")
	console.set_prompt("Plain >")
	equal(console.prompt_label.text, "Plain >", "white fixed prompt has no color wrapper")
	console.set_prompt("Debug >", Color.ORANGE)
	var debug_prompt = "[color=%s]Debug >[/color]" % Color.ORANGE.to_html()
	equal(console.prompt_label.text, debug_prompt, "colored fixed prompt uses BBCode")
	console.execute("true")
	equal(console.prompt_label.text, debug_prompt, "fixed prompt persists after execution")
	console.set_context(console.context)
	equal(console.prompt_label.text, debug_prompt, "fixed prompt persists after a context update")
	console.prompt_formatter = func(_ctx): return "Formatted >"
	equal(console.prompt_label.text, "Formatted >", "prompt formatter replaces a fixed prompt")
	console.reset_prompt()
	equal(console.prompt_label.text, default_prompt, "reset restores the dynamic light-blue prompt")
	var source_font = load("res://addons/addon_lib/gdsh/internal/source_font.tres")
	check(source_font is FontVariation, "console source font is a standalone FontVariation")
	equal(source_font.get_font_name(), "JetBrains Mono", "console bundles the editor source font")
	check(console.input.get_theme_font("font") == source_font, "console input uses the source font")
	check(console.prompt_label.get_theme_font("normal_font") == source_font, "console prompt uses the source font")
	var custom_font = source_font.duplicate()
	console.add_font_override(custom_font)
	check(console.input.get_theme_font("font") == custom_font, "font override applies to console input")
	check(console.prompt_label.get_theme_font("normal_font") == custom_font, "font override applies to prompt")
	check(console.context.scopes_hidden.has("echo"), "console context includes hidden GDSh builtins")

	var submitted:Array = []
	var finished:Array = []
	console.command_submitted.connect(func(text): submitted.append(text))
	console.command_finished.connect(func(text, result): finished.append([text, result]))
	var loaded = console.load("tests/gdsh/fixtures/commands")
	equal(loaded.size(), 4, "console loads a command directory")
	check(console.context.scopes.has("probe"), "loaded commands layer into console context")
	check(Sh.Completion.new("pro", console.context).get_completions().has("probe"), "loaded commands complete through console context")

	var result = console.execute("X=one; echo $X")
	equal(result.stdout.strip_edges(), "one", "console execute returns its result context")
	equal(console.context.variables.get("$X"), "one", "console preserves variables in its main context")
	equal(submitted, ["X=one; echo $X"], "console emits submitted signal")
	equal(finished.size(), 1, "console emits finished signal")
	check(finished[0][1] == result, "finished signal carries the result context")
	console.execute("f(){echo persisted};alias @persist=f")
	equal(console.execute("@persist").stdout.strip_edges(), "persisted", "console preserves functions and aliases")
	console.execute("cd tests/gdsh/fixtures")
	check(console.context.cwd.ends_with("/tests/gdsh/fixtures"), "console preserves cwd in its main context")
	console.execute("cd res://")

	console.execute("false")
	equal(console.execute("echo $?").stdout.strip_edges(), "1", "console preserves status between submissions")
	var exit_result = console.execute("exit 7")
	equal(exit_result.exit_code, 7, "console result preserves exit status")
	check(not console.context.exit_requested, "exit does not stop the console session")
	equal(console.execute("echo alive").stdout.strip_edges(), "alive", "console remains usable after exit")

	console.execute("echo duplicate")
	console.execute("echo another")
	console.execute("echo duplicate")
	equal(console.command_history.count("echo duplicate"), 1, "console history removes duplicates")
	equal(console.command_history.back(), "echo duplicate", "console history promotes repeated commands")
	console.input.history_requested.emit(-1)
	equal(console.input.text, "echo duplicate", "up recalls the latest command")
	console.input.history_requested.emit(1)
	equal(console.input.text, "", "down returns to an empty prompt")

	var transcript = console.create_output()
	check(transcript == console.create_output(), "console transcript creation is idempotent")
	check(console.get_child(0) == transcript, "console transcript appears above the prompt")
	check(transcript.get_theme_font("normal_font") == custom_font, "future transcript inherits the active font override")
	check(transcript.get_theme_font("mono_font") == custom_font, "font override covers transcript mono text")
	console.remove_font_override()
	check(not console.prompt_label.has_theme_font_override("normal_font"), "font removal clears the prompt override")
	check(not console.input.has_theme_font_override("font"), "font removal clears the input override")
	check(not transcript.has_theme_font_override("normal_font") and not transcript.has_theme_font_override("mono_font"), "font removal clears transcript overrides")
	console._apply_theme()
	check(not console.input.has_theme_font_override("font"), "theme changes do not restore a removed font override")
	console.add_font_override(source_font)
	check(transcript.get_theme_font("normal_font") == source_font, "font override applies to an existing transcript")
	console.execute("echo visible")
	check(console.prompt_label.text == default_prompt, "logged default prompt retains its light-blue source markup")
	check(transcript.get_parsed_text().contains("Console $ echo visible"), "transcript echoes the prompt and command")
	check(transcript.get_parsed_text().contains("visible"), "transcript appends stdout")
	console.execute("unknown_console_command")
	check(transcript.get_parsed_text().contains("stderr:"), "transcript labels stderr")
	check(transcript.get_parsed_text().contains("Unrecognized command"), "transcript appends stderr")
	console.clear_output()
	equal(transcript.get_parsed_text(), "", "console clears its transcript")
	console.clear_history()
	check(console.command_history.is_empty(), "console clears its history")

	console.prompt_formatter = func(ctx): return "Room %s >" % ctx.variables.get("$ROOM", "none")
	console.context.variables["$ROOM"] = "hall"
	console.update_prompt()
	equal(console.prompt_label.text, "Room hall >", "console supports a custom prompt formatter")
	var replacement = Sh.Context.new()
	replacement.cwd = "res://world/room"
	console.prompt_formatter = Callable()
	console.set_context(replacement)
	var room_prompt = "[color=%s]Console room $[/color]" % Color.LIGHT_BLUE.to_html()
	equal(console.prompt_label.text, room_prompt, "console prompt follows replacement context cwd")
	check(console.input.context == replacement, "console input follows replacement context")

	console.load(OVERRIDES)
	equal(console.execute("echo newest wins").stdout.strip_edges(), "layered:newest wins", "newest console command layer wins")
	console.input.text = "echo submitted"
	console.input.submit_requested.emit(console.input.text)
	equal(console.last_result.stdout.strip_edges(), "layered:submitted", "input submission uses console execution")
	equal(console.input.text, "", "input clears after submission")
	console.input.text = "pro"
	console.input.set_caret_column(3)
	console.set_context(session())
	await console.input.request_completion(true)
	check(console.input._popup != null and console.input._popup.visible, "console input shows runtime completion popup")
	check(console.input._popup._items.get_theme_font("font") == source_font, "completion popup uses the source font")
	var one_item_height = console.input._popup.custom_minimum_size.y
	console.input._popup.accept_selected()
	check(console.input.text.begins_with("probe"), "console completion inserts the selected command")
	# Accepting a choice schedules completion; the sizing checks issue their own requests.
	console.input._timer.stop()
	console.input.text = "door "
	console.input.set_caret_column(console.input.text.length())
	await console.input.request_completion(true)
	check(console.input._popup._choices.has("open"), "console completion after whitespace uses an empty filter")
	console.input.text = ""
	console.input.set_caret_column(0)
	await console.input.request_completion(true)
	var root_height = console.input._popup.custom_minimum_size.y
	check(root_height > one_item_height, "completion popup grows when the item count increases (%s/%s -> %s/%s)" % [one_item_height, 1, root_height, console.input._popup._items.item_count])
	var sample_scope = console.context.scopes["probe"]
	for index in 100:
		console.context.scopes["generated_%03d" % index] = sample_scope
	await console.input.request_completion(true)
	check(console.input._popup.custom_minimum_size.y <= console.get_window().size.y * 0.5, "completion popup height is capped at half the window")
	check(console.input._popup._items.custom_minimum_size.y > console.input._popup.custom_minimum_size.y, "capped completion choices remain scrollable")
	for index in 100:
		console.context.scopes.erase("generated_%03d" % index)
	console.input.text = "pro"
	console.input.set_caret_column(3)
	await console.input.request_completion(true)
	check(console.input._popup.custom_minimum_size.y < root_height, "completion popup shrinks after choices are removed (%s -> %s)" % [root_height, console.input._popup.custom_minimum_size.y])
	console.input.request_completion(true)
	console.input._hide_completion()
	await process_frame
	check(not console.input._popup.visible, "stale completion measurement cannot reopen a hidden popup")
	console.input.text = "pro"
	console.input.set_caret_column(3)
	await console.input.request_completion(true)
	var left = InputEventKey.new()
	left.keycode = KEY_LEFT
	left.pressed = true
	console.input._on_gui_input(left)
	check(not console.input._popup.visible, "left arrow closes the completion popup")
	console.input.text = "cmd ./addons/foo"
	console.input.set_caret_column(console.input.text.length())
	console.input.delete_word_before_caret()
	equal(console.input.text, "cmd ./addons/", "word deletion stops at a path separator")
	console.input.delete_word_before_caret()
	equal(console.input.text, "cmd ./", "word deletion includes a trailing delimiter")
	var word_delete = InputEventKey.new()
	word_delete.keycode = KEY_BACKSPACE
	word_delete.ctrl_pressed = true
	word_delete.pressed = true
	console.input.text = "echo one"
	console.input.set_caret_column(8)
	console.input._on_gui_input(word_delete)
	equal(console.input.text, "echo ", "ctrl+backspace deletes the previous word")
	console.input._timer.stop()
	check(console.format_command("echo one").begins_with("[color="), "console formats echoed commands with input colors")
	console.input.text = "echo one\necho two"
	console.input._on_text_changed() # Programmatic assignment does not emit TextEdit.text_changed.
	equal(console.input.get_line_count(), 1, "console input remains one line after pasted newlines")
	check(console.input.syntax_highlighter != null, "console input installs runtime syntax highlighting")
	await _test_console_input_consumption(console, transcript)
	console.queue_free()


func _accept_console_choice(input, prefix:String, choice:String, expected:String, suffix:String="") -> void:
	input.text = prefix + suffix
	input.set_caret_column(prefix.length())
	await input.request_completion(true)
	check(input._popup != null and input._popup.visible, "path popup visible: " + prefix)
	if input._popup == null or not input._popup.visible:
		return
	var index = input._popup._choices.find(choice)
	check(index >= 0, "path choice survives filtering: " + prefix + " -> " + choice)
	if index < 0:
		return
	input._popup._items.select(index)
	input._popup.accept_selected()
	input._timer.stop()
	equal(input.text, expected + suffix, "completion preserves path and surrounding text")
	equal(input.get_caret_column(), expected.length(), "completion caret follows inserted path")


func _test_console_path_completion() -> void:
	# Use a real directory even when res:// belongs to a packed export.
	var temp_dir = OS.get_environment("TEMP" if OS.get_name() == "Windows" else "TMPDIR")
	if temp_dir.is_empty():
		temp_dir = ProjectSettings.globalize_path("user://") if OS.get_name() == "Windows" else "/tmp"
	var fixture = temp_dir.path_join("gdsh-completion-%s" % Time.get_ticks_usec())
	var library = fixture + "/Library"
	for path in [library + "/Child", fixture + "/Elsewhere"]:
		equal(DirAccess.make_dir_recursive_absolute(path), OK, "create completion fixture")
	var ctx = session()
	ctx.cwd = fixture
	var console = Sh.Console.new(ctx)
	root.add_child(console)
	var input = console.input
	var absolute = ProjectSettings.globalize_path(fixture)
	for prefix in ["./", "./L", "./lb", absolute + "/", absolute + "/L"]:
		var base = prefix.left(prefix.rfind("/") + 1)
		await _accept_console_choice(input, "cd " + prefix, "Library", "cd " + base + "Library/")
	await _accept_console_choice(input, "cd L", "Library", "cd Library/")
	await _accept_console_choice(input, "cd ./Library/", "Child", "cd ./Library/Child/")
	await _accept_console_choice(input, "cd ./Library/Ch", "Child", "cd ./Library/Child/")
	await _accept_console_choice(input, "echo before; cd ./L", "Library", "echo before; cd ./Library/", " ; echo after")
	ctx.cwd = library
	await _accept_console_choice(input, "cd ../", "Library", "cd ../Library/")
	await _accept_console_choice(input, "cd ../L", "Library", "cd ../Library/")
	ctx.cwd = fixture
	await _accept_console_choice(input, "cd ./", "..", "cd ./../")
	await _accept_console_choice(input, "cd res://", "tests", "cd res://tests/")
	if absolute.begins_with("/"):
		# Some ancestors of the temporary directory are hidden (e.g. macOS /private).
		var root_dirs = DirAccess.get_directories_at("/")
		check(not root_dirs.is_empty(), "root has visible directories to complete")
		if not root_dirs.is_empty():
			var root_child = root_dirs[0]
			await _accept_console_choice(input, "cd /", root_child, "cd /" + root_child + "/")
			await _accept_console_choice(input, "cd /" + root_child.left(1), root_child, "cd /" + root_child + "/")
	for prefix in ["./NoMatch", "./Missing/", absolute + "/NoMatch"]:
		input.text = "cd " + prefix
		input.set_caret_column(input.text.length())
		await input.request_completion(true)
		check(not input._popup.visible, "unmatched paths hide popup: " + prefix)

	var options = Sh.Options.new()
	options.add_separator("Empty")
	options.add_separator("Commands")
	options.add_option("Display", {&"insert": "replacement"})
	options.add_separator("Other")
	options.add_option("unrelated")
	options.add_separator("Trailing")
	input.completion_factory = func(text, context, caret):
		var request = FixedCompletion.new(text, context, caret)
		request.choices = options.get_options()
		return request
	for needle in ["Di", "rp"]:
		input.text = needle
		input.set_caret_column(needle.length())
		await input.request_completion(true)
		equal(input._popup._items.item_count, 2, "filter keeps matching choice and its group")
		equal(input._popup._items.get_item_text(0), "── Commands ──", "group label survives text filtering")
		check(input._popup._items.is_item_disabled(0), "separator cannot be selected")
		input._popup.accept_selected()
		input._timer.stop()
		equal(input.text, "replacement ", "matching label or insertion accepts custom insertion")
	input.text = ""
	input.set_caret_column(0)
	await input.request_completion(true)
	equal(input._popup._items.item_count, 4, "cleanup also runs with an empty filter")
	input.text = "missing"
	input.set_caret_column(input.text.length())
	await input.request_completion(true)
	check(not input._popup.visible, "empty groups hide popup")
	options.remove_option("Display")
	options.remove_option("unrelated")
	input.text = ""
	input.set_caret_column(0)
	await input.request_completion(true)
	check(not input._popup.visible, "separator-only results hide popup")
	input.completion_factory = Callable()
	await _accept_console_choice(input, "pro", "probe", "probe ")
	console.free()
	for path in [library + "/Child", library, fixture + "/Elsewhere", fixture]:
		equal(DirAccess.remove_absolute(path), OK, "remove completion fixture")


func _test_console_input_consumption(console, transcript:RichTextLabel) -> void:
	var probe = InputProbe.new()
	root.add_child(probe)
	console.size = Vector2(640, 400)
	console.input.release_focus()
	var baseline_key = InputEventKey.new()
	baseline_key.keycode = KEY_F9
	baseline_key.pressed = true
	Input.parse_input_event(baseline_key)
	await process_frame
	check(probe.events.size() == 1, "input probe receives an unhandled key without console focus")
	probe.events.clear()
	console.input.grab_focus()
	await process_frame
	for state in [
		{"pressed": true, "echo": false},
		{"pressed": false, "echo": false},
		{"pressed": true, "echo": true},
	]:
		var key = InputEventKey.new()
		key.keycode = KEY_F10
		key.pressed = state.pressed
		key.echo = state.echo
		Input.parse_input_event(key)
		await process_frame
	check(probe.events.is_empty(), "focused console consumes key presses, releases, and repeats")
	console.input.text = ""
	var typed_key = InputEventKey.new()
	typed_key.keycode = KEY_X
	typed_key.unicode = "x".unicode_at(0)
	typed_key.pressed = true
	Input.parse_input_event(typed_key)
	await process_frame
	equal(console.input.text, "x", "consumed keyboard input still edits the focused console")
	check(probe.events.is_empty(), "typed console input remains consumed")

	console.input.release_focus()
	transcript.clear()
	for index in 80:
		transcript.add_text("line %d\n" % index)
	await process_frame
	var baseline_wheel = InputEventMouseButton.new()
	baseline_wheel.position = Vector2(639, 479)
	baseline_wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	baseline_wheel.pressed = true
	Input.parse_input_event(baseline_wheel)
	await process_frame
	check(probe.events.size() == 1, "input probe receives a wheel event outside the console")
	probe.events.clear()
	transcript.scroll_to_line(0)
	await process_frame
	var initial_scroll = transcript.get_v_scroll_bar().value
	var scroll_inside = InputEventMouseButton.new()
	scroll_inside.position = transcript.global_position + Vector2(4, 4)
	scroll_inside.button_index = MOUSE_BUTTON_WHEEL_DOWN
	scroll_inside.pressed = true
	Input.parse_input_event(scroll_inside)
	await process_frame
	check(transcript.get_v_scroll_bar().value > initial_scroll, "consumed wheel events still scroll the transcript")
	check(probe.events.is_empty(), "scrolling transcript does not pass wheel events to the game")
	for at_end in [false, true]:
		transcript.scroll_to_line(transcript.get_line_count() - 1 if at_end else 0)
		await process_frame
		var wheel = InputEventMouseButton.new()
		wheel.position = transcript.global_position + Vector2(4, 4)
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN if at_end else MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		Input.parse_input_event(wheel)
		await process_frame
	check(probe.events.is_empty(), "transcript consumes wheel events at both scroll limits")
	var pan = InputEventPanGesture.new()
	pan.position = transcript.global_position + Vector2(4, 4)
	pan.delta = Vector2(0, 1)
	Input.parse_input_event(pan)
	await process_frame
	check(probe.events.is_empty(), "transcript consumes pan gestures")
	check(transcript.mouse_filter == Control.MOUSE_FILTER_STOP, "transcript stops mouse events")
	check(not transcript.mouse_force_pass_scroll_events, "transcript does not force scroll events to pass")
	probe.queue_free()

func _test_host_extensions():
	var raw = Sh.Load.load_command(FIXTURES + "raw/raw.gd")
	var ctx = session()
	ctx.scopes_hidden["raw"] = {"script": raw}
	var unregistered = Sh.Context.new_ctx("routed raw", ctx)
	var routed = run_text("raw one", unregistered)
	check(routed.exit_code != 0 and routed.stderr.contains("takes raw arguments"), "raw command outside command position reports usage")
	ctx.collect_raw_commands()
	equal(Array(ctx.raw_commands), ["raw"], "raw names collected from command data")
	check(Sh.Context.new_ctx("child", ctx).raw_commands == ctx.raw_commands, "child contexts share raw names")
	check(run_text("raw 'open", Sh.Context.new_ctx("unclosed", ctx)).stderr.contains("Unclosed raw command argument"), "unclosed raw quote reports an error")
	check(run_text("raw (open", Sh.Context.new_ctx("unclosed", ctx)).stderr.contains("Unclosed raw argument group"), "unclosed raw group reports an error")
	ctx.host_data["binding"] = "host"
	var resolver = func(name, request):
		if name == "fallback":
			check(request.host_data.get("binding") == "host", "host bindings inherited")
			return request.scopes.get("counter")
		return null
	ctx.scope_resolver = resolver
	for row in [
		["raw $value $$(native ${syntax})", "$value $$(native ${syntax})"],
		["raw 'a | b' | sink", "stdin:'a | b'"],
		["if true { raw one }", "one"],
		["f(){ raw two }; f", "two"],
		["(raw three)", "three"],
		["echo $(raw four)", "four"],
		["alias @r = raw five; @r", "five"],
		["raw six 2>discard", "six"],
		["raw one >discard two | sink", "stdin:"],
		["2>discard raw before", "before"],
		['raw "$$(printf "a | b")"', '"$$(printf "a | b")"'],
	]:
		var result = Sh.Context.new_ctx("host test", ctx)
		run_text(row[0], result)
		equal(result.stdout.strip_edges(), row[1], "raw host command: " + row[0])
		equal(result.exit_code, 0, "raw status: " + row[0])
	raw.calls = 0
	run_text("false && raw $(counter)", Sh.Context.new_ctx("skip", ctx))
	equal(raw.calls, 0, "raw handler stays lazy in skipped branch")
	check(Sh.Completion.new("raw $$(unknown ", ctx).get_completions().has("raw:$$(unknown "), "raw completion sees source")
	equal(raw.calls, 0, "raw completion never executes")
	var result = run_text("raw fail || echo recovered", Sh.Context.new_ctx("failure", ctx))
	equal(result.stdout.strip_edges(), "fail\nrecovered", "raw failure drives logical branch")
	check(result.stderr.contains("raw diagnostic"), "raw stderr captured")
	check(run_text("fallback", Sh.Context.new_ctx("resolver", ctx)).exit_code == 0, "fallback resolver dispatch")
	check(run_text("(fallback)", Sh.Context.new_ctx("resolver subshell", ctx)).exit_code == 0, "fallback resolver survives subshell")
	Sh.Completion.new("fallback ", ctx).get_completions()
	var override = ctx.scopes["probe"]
	ctx.scopes["fallback"] = override
	check(ctx.get_scope("fallback") == override, "registered scope precedes resolver")
	var child = Sh.Context.new_ctx("child", ctx, true)
	child.host_data["binding"] = "other"
	equal(ctx.host_data.binding, "host", "host binding dictionaries are independent")
