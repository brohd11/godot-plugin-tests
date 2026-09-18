extends RefCounted
## GDSh runtime checks, driven by runtime_test.gd (headless and editor console `test`).

const Sh = preload("res://addons/addon_lib/gdsh/_ns/gd_sh.gd")
const Utils = preload("res://addons/addon_lib/gdsh/internal/utils.gd")
const NodePaths = preload("res://addons/addon_lib/gdsh/internal/node_paths.gd")
const FIXTURES = "res://tests/gdsh/fixtures/"
const COMMANDS = FIXTURES + "commands/"
const OVERRIDES = FIXTURES + "overrides/"
var checks = 0
var failures = 0
var report:Array[String] = []


class InputProbe extends Node:
	var events:Array[InputEvent] = []

	func _unhandled_input(event:InputEvent) -> void:
		events.append(event)


class FixedCompletion extends Sh.Completion:
	var choices:Dictionary

	func get_completions() -> Dictionary:
		_parse()
		return choices


func run_sync():
	_test_utils()
	_test_execution()
	_test_grammar()
	_test_redirection()
	_test_syntax_errors()
	_test_loading()
	_test_fresh_user_commands()
	_test_builtins()
	_test_hidden()
	_test_clear()
	_test_new_ctx()
	_test_value_conversion()
	_test_method_call()
	_test_files()
	_test_working_node()
	_test_bare_resolution()
	_test_script_target()
	_test_target_members()
	_test_script_access()
	_test_pwn()
	_test_list_global()
	_test_completion()
	_test_structured_completion()
	_test_hidden_scopes()
	_test_host_extensions()
	_test_highlighting()
	_test_echo_formatting()
	_test_script_highlighter_logic()
	_test_streaming()


## Console popup sizing and input delivery need rendered frames; headless only.
func run_frames():
	await _test_console()
	await _test_console_popup_navigation()
	await _test_console_path_completion()
	await _test_console_node_completion()
	await _test_console_mixed_path_completion()
	await _test_async()
	await _test_streaming_console()
	if not Engine.is_editor_hint():
		await preload("res://tests/gdsh/tui_tests.gd").new().run(self)
		await preload("res://tests/gdsh/tui_program_tests.gd").new().run(self)


func _run_async(text:String, ctx:Sh.Context) -> Sh.Context:
	return await Sh.Execute.execute_command_multiline(text, Sh.Context.new_ctx("async", ctx))

func _async_output(text:String, ctx:Sh.Context) -> String:
	var result = await _run_async(text, ctx)
	return result.stdout.strip_edges()

## Commands that await frames: every construct waits for them before moving on.
func _test_async():
	var ctx = session()
	ctx.scopes.merge(Sh.Load.load_directory(FIXTURES + "async/"), true)
	var start = Engine.get_process_frames()
	equal(await _async_output("wait_frames 2 first && echo after", ctx), "waited:first\nafter", "&& waits for an async command")
	check(Engine.get_process_frames() - start >= 2, "async command spans frames")
	equal(await _async_output("wait_frames 1 --fail x || echo handled", ctx), "waited:x\nhandled", "|| sees the async failure")
	equal(await _async_output("wait_frames 1 --fail x; echo $?", ctx), "waited:x\n1", "$? is the async status")
	equal(await _async_output("wait_frames 1 piped | sink", ctx), "stdin:waited:piped", "pipe waits for the async stage")
	var path = "user://gdsh_async_redirect.txt"
	await _run_async("wait_frames 1 filed > " + path, ctx)
	equal(FileAccess.get_file_as_string(path), "waited:filed\n", "redirect captures async output")
	DirAccess.remove_absolute(path)
	equal(await _async_output("for n in a b { wait_frames 1 $n }", ctx), "waited:a\nwaited:b", "for body waits")
	equal(await _async_output("while true { wait_frames 1 loop; break }", ctx), "waited:loop", "while body waits")
	equal(await _async_output("if wait_frames 1 cond { echo yes }", ctx), "waited:cond\nyes", "if condition waits")
	equal(await _async_output("f() { wait_frames 1 fn; return 3 }; f; echo $?", ctx), "waited:fn\n3", "function waits and returns")
	equal(await _async_output("(wait_frames 1 sub); echo next", ctx), "waited:sub\nnext", "subshell waits")
	var substituted = await _run_async("echo $(wait_frames 1 sub) && echo no", ctx)
	check(substituted.stdout.is_empty() and substituted.exit_code == 2 and substituted.stderr.contains("cannot run inside $(...)"), "async substitution fails the command: " + substituted.stderr)
	for i in 3: await _tree().process_frame # The stopped substitution body resumes harmlessly.
	var sync_result = _sync("execute_command_multiline", ["echo now", Sh.Context.new_ctx("sync", ctx)])
	check(sync_result is Sh.Context and sync_result.stdout.strip_edges() == "now", "input that never pauses finishes in the calling frame")
	var console = Sh.Console.new(Sh.Context.new_ctx("async console", ctx))
	console.execute("wait_frames 2 slow") # Not awaited: returns at the first pause.
	check(console.is_busy and not console.input.editable, "console is busy while a command waits")
	var refused = _submit(console, "echo second")
	check(refused.exit_code == 2 and refused.stderr.contains("busy") and not console.command_history.has("echo second"), "busy console refuses submissions")
	var finished = await console.command_finished
	equal(finished[1].stdout.strip_edges(), "waited:slow", "console result waits for the command")
	check(not console.is_busy and console.input.editable, "console unlocks after the command")
	await _tree().process_frame # Resumed inside command_finished's emission, which locks the console.
	console.free()


func stream_session():
	var ctx = session()
	ctx.scopes.merge(Sh.Load.load_directory(FIXTURES + "stream/"), true)
	# The raw fixture lives outside `commands/`, and the parser only produces raw args for
	# names collected here.
	ctx.scopes.merge(Sh.Load.load_directory(FIXTURES + "raw/"), true)
	ctx.collect_raw_commands()
	return ctx

## Wait for a console to go idle. Bounded, and never waits on `command_finished`: a submission
## that never pauses emits it during `execute()`, before an await could register.
func _await_idle(console) -> void:
	for i in 120:
		if not console.is_busy: return
		await _tree().process_frame

## Run input with a recording sink installed. Returns the context and every streamed chunk.
func _streamed(text:String, ctx:Sh.Context=null) -> Dictionary:
	if ctx == null: ctx = stream_session()
	var log:Array = []
	ctx.output_sink = func(chunk:String, is_error:bool): log.append([chunk, is_error])
	var result = _sync("execute_command_multiline", [text, ctx])
	ctx.clear_output_sink()
	return {"ctx": result, "log": log}

func _joined(log:Array, is_error:bool) -> String:
	var joined = ""
	for entry in log:
		if entry[1] == is_error: joined += entry[0]
	return joined


## The live output channel: text reaches the host as a command produces it, exactly once, and
## only when it is genuinely screen-bound.
func _test_streaming():
	var data = _streamed("echo a; echo b")
	equal(_joined(data.log, false), "a\nb\n", "streams each line as it is produced")
	equal(data.log.size(), 2, "each echo streams one chunk")
	equal(data.ctx.stdout, _joined(data.log, false), "streamed stdout matches the buffer")

	data = _streamed("sink")
	equal(_joined(data.log, false), "stdin:\n", "streams stdout")
	equal(_joined(data.log, true), "sink diagnostic\n", "streams stderr")
	check(data.log.size() == 2 and not data.log[0][1] and data.log[1][1], "stderr interleaves in production order")

	# Redirection: a routed stream becomes file data and must not reach the host.
	data = _streamed("echo a >discard")
	equal(data.log.size(), 0, "redirected stdout does not stream")
	data = _streamed("sink 2>discard")
	equal(_joined(data.log, false), "stdin:\n", "a routed stderr leaves stdout streaming")
	equal(_joined(data.log, true), "", "redirected stderr does not stream")
	data = _streamed("sink &>discard")
	equal(data.log.size(), 0, "&> routes both streams away from the host")

	# A leaked capture counter would silently disable streaming for the rest of the submission.
	data = _streamed("echo a >discard; echo b")
	equal(_joined(data.log, false), "b\n", "streaming resumes after a redirected command")
	data = _streamed("echo a >missing_dir/out.txt; echo b")
	check(_joined(data.log, true).contains("cannot open"), "a failed redirect streams its diagnostic")
	equal(_joined(data.log, false), "b\n", "streaming resumes after a failed redirect")

	# Pipelines: only the final stage reaches the host, and stderr is never piped.
	data = _streamed("echo a | sink")
	equal(_joined(data.log, false), "stdin:a\n", "only the final pipe stage streams stdout")
	equal(_joined(data.log, true), "sink diagnostic\n", "a pipe stage still streams stderr")
	data = _streamed("echo a | sink | sink")
	equal(_joined(data.log, false), "stdin:stdin:a\n", "intermediate pipe stages do not stream")

	# `$(...)`: its stdout is the value, not screen output; its stderr still shows, once.
	data = _streamed("echo $(counter)")
	equal(data.log.size(), 1, "a substitution body does not stream its value")
	data = _streamed("echo $(nope_missing_command)")
	equal(_joined(data.log, true).count("Unrecognized command"), 1, "a failing substitution streams its error once")

	# Roll-ups emit once each: the child streams, the parent absorbs.
	for sample in [
		["(echo a)", "subshell"],
		["for x in a { echo $x }", "for body"],
		["f() { echo a }; f", "function body"],
		["if true { echo a }", "if body"],
	]:
		data = _streamed(sample[0])
		equal(_joined(data.log, false), "a\n", "streams once through a " + sample[1])
		equal(data.ctx.stdout, _joined(data.log, false), "buffer matches the stream through a " + sample[1])
	data = _streamed("raw hello")
	equal(_joined(data.log, false), "hello\n", "a raw command streams once")
	equal(_joined(data.log, true), "raw diagnostic\n", "a raw command streams stderr once")

	# Children inherit a capture in progress.
	data = _streamed("(echo a | sink) >discard")
	equal(_joined(data.log, false), "", "a redirected subshell suppresses its pipeline stdout")
	data = _streamed("for x in a b { echo $x | sink }")
	equal(_joined(data.log, false), "stdin:a\nstdin:b\n", "a loop streams only its final pipe stages")

	# write_output keeps text verbatim, including a partial line.
	data = _streamed("emit")
	equal(data.log.size(), 2, "verbatim writes stream as written")
	equal(_joined(data.log, false), "ab\n", "verbatim writes are not normalized")
	data = _streamed("echo")
	equal(_joined(data.log, false), "\n", "a bare echo streams its blank line")

	# Propagation, and the unchanged no-sink path the MCP bridge uses.
	var ctx = stream_session()
	ctx.output_sink = func(_t, _e): pass
	ctx.begin_capture(true, false)
	var child = Sh.Context.new_ctx("child", ctx)
	check(child.output_sink.is_valid(), "new_ctx copies the sink")
	check(not child.should_stream(), "new_ctx copies stdout capture")
	check(child.should_stream(true), "capture state is tracked per stream")
	ctx.end_capture(true, false)
	equal(run_text("echo a", stream_session()).stdout, "a\n", "a context with no sink behaves as before")


## The transcript shows streamed output while the command runs, and never prints it twice.
func _test_streaming_console():
	var console = Sh.Console.new(Sh.Context.new_ctx("stream console", stream_session()))
	var transcript = console.create_output()
	_tree().root.add_child(console)
	console.execute("stream_probe 3") # Not awaited: returns at the first pause.
	await _tree().process_frame
	await _tree().process_frame
	check(console.is_busy, "the probe is still running while its output streams")
	check(transcript.get_parsed_text().contains("line0"), "transcript shows output before the command finishes")
	await _await_idle(console)
	var result = console.last_result
	var shown = transcript.get_parsed_text()
	equal(shown.count("line0"), 1, "streamed output is not printed again by the result")
	equal(shown.count("line2"), 1, "the final line appears exactly once")
	equal(result.stdout, "line0\nline1\nline2\n", "the buffer still holds the whole output")
	check(not result.output_sink.is_valid(), "the sink is removed when the submission ends")
	console.queue_free()

	# Streaming off renders exactly as it did before: one append once the command finishes.
	var plain = Sh.Console.new(Sh.Context.new_ctx("plain console", stream_session()))
	var plain_output = plain.create_output()
	_tree().root.add_child(plain)
	plain.stream_output = false
	# More lines than the frames waited below, so the probe is certainly still running when
	# the transcript is checked: a finished command would print its result legitimately.
	plain.execute("stream_probe 6")
	await _tree().process_frame
	await _tree().process_frame
	check(plain.is_busy, "the probe is still running with streaming off")
	check(not plain_output.get_parsed_text().contains("line0"), "streaming off shows nothing until the end")
	await _await_idle(plain)
	equal(plain_output.get_parsed_text().count("line0"), 1, "streaming off still prints the result once")
	plain.queue_free()


func finish() -> Array[String]:
	report.append("GDSh: %d checks, %d failures" % [checks, failures])
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

func session():
	var ctx = Sh.Context.new()
	ctx.scopes.merge(Sh.Load.load_directory(COMMANDS), true)
	return ctx

func flag_session():
	var ctx = session()
	ctx.scopes.merge(Sh.Load.load_directory(FIXTURES + "flags/"), true)
	return ctx

func run_text(text:String, ctx:Sh.Context=null):
	if ctx == null:
		ctx = session()
	return _sync("execute_command_multiline", [text, ctx])

## Synchronous engine call for input that never pauses. The Callable hides the coroutine from
## the analyzer, and a coroutine that never pauses returns its Context directly.
## Async checks use `await Sh.Execute...` instead.
func _sync(method:String, args:Array):
	return Callable(Sh.Execute, method).callv(args)

## Synchronous console submission, as `_sync`. A submission that pauses must not use this:
## taking the value of a paused call is a runtime error.
func _submit(console, text:String):
	return Callable(console, "execute").call(text)

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
	equal(output("X = ab; echo \"${X}1\""), "ab1", "braced variable joins following text")
	equal(output("X = ab; echo ${X}_y"), "ab_y", "unquoted braced variable")
	equal(output("X = ab; echo '${X}'"), "${X}", "single-quoted braced variable is literal")
	equal(output("f() { echo ${1}x }; f a"), "ax", "braced positional variable")
	var bad_brace = run_text("echo ${X")
	check(bad_brace.exit_code == Sh.Context.ExitCode.ERR and bad_brace.stderr.contains("Bad substitution"), "unclosed braced variable is a syntax error: " + bad_brace.stderr)
	equal(run_text('echo "[color=ff0000]a[/color]"').stdout.strip_edges(), "[color=ff0000]a[/color]", "displayed output keeps color markup")
	equal(run_text('echo "[color=#ff0000]a[/color] [lb]b" | sink').stdout.strip_edges(), "stdin:a [b", "piped output drops color markup")
	equal(run_text('X = $(echo "[color=red]a[/color]"); echo $X').stdout.strip_edges(), "a", "substitution captures plain text")
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
	equal(output("probe -l one"), "default:true:one:", "short flag")
	var probe_bad = run_text("probe -lz")
	check(probe_bad.exit_code == Sh.Context.ExitCode.ERR and probe_bad.stderr.contains("Unrecognized flag: -z"), "unknown short flag letter: " + probe_bad.stderr)
	equal(output("probe '-l' -5"), "default:false:-l,-5:", "quoted dash words and numbers stay positional")
	check(run_text("probe --help").stdout.contains("-l, --loud"), "help lists short forms")
	equal(run_text("flagvars", flag_session()).stdout.strip_edges(), "default:0:0.5:false:false:0,0", "flag vars keep defaults")
	equal(run_text('flagvars --text="two words" --count=3 --ratio=1.5 --dry-run --size="(1, 2)"', flag_session()).stdout.strip_edges(), "two words:3:1.5:false:true:1,2", "value flags convert to the var type")
	equal(run_text("flagvars -l", flag_session()).stdout.strip_edges(), "default:0:0.5:true:false:0,0", "short flag sets bool var")
	var bad_value = run_text("flagvars --count=abc", flag_session())
	check(bad_value.exit_code == Sh.Context.ExitCode.ERR and bad_value.stderr.contains("Invalid value for --count=abc") and bad_value.stdout.strip_edges() == "", "unconvertible flag value fails: " + bad_value.stderr)
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
	equal(_sync("execute_command", [" "]).exit_requested, false, "blank command is harmless")
	equal(run_text("false").exit_code, 1, "false status")
	equal(run_text("break").exit_code, 2, "break outside loop")
	equal(run_text("return").exit_code, 2, "return outside function")
	check(run_text("echo --help").stdout.contains("Echos"), "per-command help")
	equal(run_text("echo --help").exit_code, 0, "--help exits 0")
	var short_help = run_text("echo -h")
	check(short_help.exit_code == 0 and short_help.stdout.contains("Echos"), "-h prints help")
	equal(output("echo '-h'"), "-h", "quoted -h is an argument")
	equal(output("[ -n abc ] && echo yes"), "yes", "dash words stay arguments for commands without short flags")

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
	check(not builtins.has("tui_demo"), "documentation demo is not a builtin")
	check(not complete("builtins ", Sh.Context.new()).has("tui_demo"), "documentation demo is absent from builtin completion")
	check(run_text("tui_demo").stderr.contains("Unrecognized command"), "documentation demo is not executable by default")
	check(builtins.has("help") and builtins.has("clear"), "help and clear are builtins")
	check(builtins.has("builtins") and builtins.has("hidden"), "builtins and hidden namespaces are registered")
	for name in ["os", "global", "cat", "pwd"]:
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
	var public_names = ["break", "continue", "return", "exit", "shift", "true", "false", "[", "expr", "echo", "source", "cd", "cn", "pwn", "node", "gdsh", "script", "help", "hidden", "clear", "new_ctx", "undoredo"]
	var choices = complete("builtins ", ctx)
	var children = ctx.get_scope("builtins").script.new().get_commands()
	equal(children.size(), public_names.size(), "parent discovers only public builtins")
	for name in public_names:
		check(children.has(name) and choices.has(name), "builtin child routing and completion: " + name)
	for name in ["__function__", "__ambiguous__"]:
		check(ctx.scopes_hidden.has(name) and not choices.has(name), "internal builtin remains registered but is not suggested: " + name)
	check(complete("builtins ec", ctx).has("echo"), "partial builtin child completion")
	ctx.cwd = COMMANDS
	check(complete("builtins cd ", ctx).has("door"), "builtin child delegates directory completion")

	var listing = run_text("builtins")
	equal(listing.exit_code, 0, "bare builtins succeeds")
	check(listing.stdout.contains("Subcommands:"), "bare builtins lists children")
	for name in public_names:
		check((listing.stdout + "\n").contains("\n  " + name + "\n"), "builtin listing includes: " + name)
	check(not listing.stdout.contains("__function__") and not listing.stdout.contains("__ambiguous__"), "builtin help omits internals")
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

func _test_hidden():
	var ctx = Sh.Context.new()
	check(ctx.scopes_hidden.has("hidden") and ctx.scopes.is_empty(), "hidden parent is a hidden builtin")
	var parent = ctx.get_scope("hidden").script.new()
	parent._initialize(ctx)
	equal(parent.get_commands().keys(), ["builtins", "gdsh", "node", "script"], "hidden lists only discoverable hidden scopes by default")
	var choices = complete("hidden ", ctx)
	check(choices.has("builtins"), "hidden completes discoverable namespaces")
	for name in ["echo", "cd", "help", "clear", "__function__", "hidden"]:
		check(not choices.has(name), "hidden omits non-discoverable or internal command: " + name)
	check(complete("hidden builtins ", ctx).has("echo"), "namespaces list non-discoverable children")
	equal(output("hidden builtins echo hello"), "hello", "hidden routes through a namespace")
	var listing = run_text("hidden").stdout + "\n"
	check(listing.contains("\n  builtins\n") and not listing.contains("\n  echo\n"), "bare hidden lists discoverable children")
	var help_text = run_text("help").stdout + "\n"
	check(help_text.contains("\n  builtins\n") and help_text.contains("\n  hidden\n") and not help_text.contains("\n  echo\n"), "help omits non-discoverable commands")
	equal(output("echo direct"), "direct", "non-discoverable commands still run directly")

	var visible = session()
	visible.scopes["quiet"] = {"script": Sh.Load.load_command(FIXTURES + "quiet/quiet.gd")}
	var root_choices = complete("", visible)
	check(root_choices.has("probe") and not root_choices.has("quiet"), "root completion omits non-discoverable visible scopes")
	equal(run_text("quiet", Sh.Context.new_ctx("quiet", visible)).stdout.strip_edges(), "quiet ran", "non-discoverable visible scope still runs")
	check(not run_text("help", Sh.Context.new_ctx("help", visible)).stdout.contains("quiet"), "help omits non-discoverable visible scopes")

	var probe = Sh.Load.load_command(COMMANDS + "probe.gd")
	ctx.scopes_hidden["probe_alias"] = {"script": probe}
	ctx.scopes_hidden["probe_object"] = {"script": probe.new()}
	choices = complete("hidden ", ctx)
	check(choices.has("probe_alias") and choices.has("probe_object"), "hidden lists runtime scopes by registered name")
	equal(run_text("hidden probe_object", Sh.Context.new_ctx("object", ctx)).exit_code, 0, "hidden routes object scopes")

	ctx = Sh.Context.new()
	var independent = Sh.Context.new()
	ctx.scopes_hidden.erase("hidden")
	check(independent.has_scope("hidden"), "independent hidden parent registration")
	var child = Sh.Context.new_ctx("child", independent)
	child.scopes_hidden.erase("hidden")
	check(independent.has_scope("hidden"), "child parent registration is independent")
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
	_write(temp.path_join("no_tag.gdsh"), "echo untagged")
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
	check(not _sync("source_file", [temp.path_join("missing.gdsh")]).stderr.is_empty(), "missing source diagnostic")
	equal(_sync("source_file", [temp.path_join("not_gdsh.txt")]).exit_code, 1, "non-gdsh rejected")
	# The extension is the only gate now: source_file still demands #!gdsh, the gdsh command does not.
	# Built from temp, not ctx.cwd: the cd checks above have already moved cwd into child/.
	equal(run_text('"' + ProjectSettings.globalize_path(temp).path_join("no_tag.gdsh") + '"',
			Sh.Context.new_ctx("untagged", ctx)).stdout.strip_edges(),
			"untagged", "a .gdsh script runs without a #!gdsh tag")
	for name in ["source.gdsh", "args.gdsh", "not_gdsh.txt", "no_tag.gdsh"]:
		DirAccess.remove_absolute(temp.path_join(name))
	DirAccess.remove_absolute(temp.path_join("child"))
	DirAccess.remove_absolute(temp)

## The working node: cwn is to node paths what cwd is to file paths, and cn is its cd.
func _test_working_node():
	var root = _tree().root
	equal(Sh.Context.new().cwn, "/root", "default working node")

	var fixture = Node.new()
	fixture.name = "GDShCwnFixture"
	var alpha = Node.new()
	alpha.name = "Alpha"
	var beta = Node.new()
	beta.name = "Beta"
	root.add_child(fixture)
	fixture.add_child(alpha)
	alpha.add_child(beta)
	var base = "/root/GDShCwnFixture"

	equal(NodePaths.path_of(alpha), base + "/Alpha", "absolute path of a node")
	equal(NodePaths.resolve(base + "/Alpha"), alpha, "absolute node path resolves")
	equal(NodePaths.resolve("Alpha", base), alpha, "relative node path resolves from cwn")
	equal(NodePaths.resolve("Alpha/Beta", base), beta, "nested relative node path resolves")
	equal(NodePaths.resolve("..", base + "/Alpha"), fixture, "'..' resolves to the parent")
	check(NodePaths.resolve("Missing", base) == null, "a missing node resolves to null")
	# res:// must stay a script target; a node lookup would shadow it.
	check(NodePaths.resolve("res://addons/addon_lib/gdsh/load.gd", base) == null, "resource paths are not node paths")
	equal(NodePaths.cwn_node(base + "/Gone"), root, "an unresolvable cwn falls back to the tree root")

	var ctx = session()
	run_text("cn " + base, ctx)
	equal(ctx.cwn, base, "cn propagates an absolute node path")
	run_text("cn Alpha", ctx)
	equal(ctx.cwn, base + "/Alpha", "relative cn propagates")
	run_text("cn ..", ctx)
	equal(ctx.cwn, base, "cn .. walks up")
	var before = ctx.cwn
	var failed = run_text("cn Missing", Sh.Context.new_ctx("cn", ctx))
	equal(ctx.cwn, before, "failed cn preserves cwn")
	equal(failed.exit_code, 2, "failed cn status")

	equal(Sh.Context.new_ctx("child", ctx).cwn, base, "new_ctx inherits cwn")
	equal(Sh.Context.new_ctx("subshell", ctx, true).cwn, base, "a subshell inherits cwn")
	# Completion builds its own context; offering children proves cwn was carried into it.
	var choices = complete("cn ", ctx)
	check(choices.has("Alpha"), "cn completes child nodes under cwn")
	check(choices.has(".."), "cn completes the parent")

	var internal = Node.new()
	internal.name = "Internal"
	alpha.add_child(internal, false, Node.INTERNAL_MODE_BACK)
	for prefix in ["cn ", "node ", ""]:
		for path in ["Alpha/", "Alpha/B", "./Alpha/B", base + "/Alpha/B"]:
			choices = complete(prefix + path, ctx)
			check(choices.has("Beta"), "nested node completion: " + prefix + path)
			if choices.has("Beta"):
				var meta = choices.Beta[Sh.Options.Keys.METADATA]
				equal(meta[Sh.Options.Keys.INSERT], path.left(path.rfind("/") + 1) + "Beta", "node insertion keeps the path prefix")
		for path in ["Alpha/", "Alpha/I"]:
			equal(complete(prefix + path, ctx).has("Internal"), prefix != "cn ", "internal completion defaults: " + prefix + path)
		choices = complete(prefix + "/", ctx)
		equal(choices.has(str(root.name)), prefix != "", "absolute root suggestions require an explicit node command: " + prefix)
		check(not choices.has("Alpha"), "absolute slash does not list cwn children: " + prefix)
		check(not complete(prefix + "Missing/", ctx).has("Alpha"), "missing parents do not fall back to cwn: " + prefix)
	for flag in ["--internal", "-i"]:
		for path in ["Alpha/", "Alpha/I", base + "/Alpha/I"]:
			check(complete("cn " + flag + " " + path, ctx).has("Internal"), "cn internal flag completes children: " + flag + " " + path)
		check(complete("cn " + flag + " Alpha/", ctx).has("Beta"), "cn internal flag retains ordinary children: " + flag)
		check(not complete("cn " + flag + " ", ctx).has("--internal"), "cn hides consumed internal flag: " + flag)
		var target_ctx = Sh.Context.new_ctx("internal cn", ctx, true)
		var result = run_text("cn " + flag + " Alpha/Internal", target_ctx)
		equal(result.exit_code, 0, "cn accepts internal flag: " + flag)
		equal(target_ctx.cwn, base + "/Alpha/Internal", "cn flag selects internal child: " + flag)
	check(not complete("cn Alpha/", ctx).has("Internal"), "cn internal flag does not leak between requests")
	for text in ["cn ", "cn --int", "cn -", "cn Alpha "]:
		check(complete(text, ctx).has("--internal"), "cn suggests its internal flag: " + text)
	check(run_text("cn --help", Sh.Context.new_ctx("help", ctx)).stdout.contains("-i, --internal"), "cn help includes both internal flag forms")
	var explicit_ctx = Sh.Context.new_ctx("explicit internal", ctx, true)
	equal(run_text("cn Alpha/Internal", explicit_ctx).exit_code, 0, "explicit internal path works without a completion flag")
	for text in ["", "Al", "Alpha", "/", "/root"]:
		check(not complete(text, ctx).has("Alpha"), "bare node suggestions wait for a slash after the first node: " + text)
	check(complete("Alpha ", ctx).has("call"), "bare node target still completes subcommands")
	check(complete("node Alpha ", ctx).has("call"), "explicit node target still completes subcommands")
	check(complete("Alpha call ", ctx).has("--engine"), "bare node still routes member completion")
	check(not complete("cn Alpha ", ctx).has("Beta"), "cn does not replace an already finished path")
	check(not complete("echo Alpha/", ctx).has("Beta"), "node completion stays out of other arguments")
	check(ctx.get_scope("Alpha/B") == null, "completion leaves execution resolution strict")
	equal(ctx.cwn, base, "node completion does not change cwn")

	root.remove_child(fixture)
	fixture.free()

## Bare targets in command position: core classifies the token and routes it to the handler,
## so a node path is a command without any host resolver installed.
func _test_bare_resolution():
	var root = _tree().root
	var fixture = Node.new()
	fixture.name = "GDShBareFixture"
	var child = Node.new()
	child.name = "Child"
	root.add_child(fixture)
	fixture.add_child(child)
	var base = "/root/GDShBareFixture"
	var ctx = session()

	equal(run_text(base, Sh.Context.new_ctx("bare", ctx)).stdout.strip_edges(), base,
			"a bare absolute node path prints its path")
	equal(run_text(base + "/Child", Sh.Context.new_ctx("bare", ctx)).stdout.strip_edges(), base + "/Child",
			"a bare nested node path resolves")
	equal(run_text("node " + base, Sh.Context.new_ctx("explicit", ctx)).stdout.strip_edges(), base,
			"the explicit node command resolves the same path")

	ctx.cwn = base
	equal(run_text("Child", Sh.Context.new_ctx("relative", ctx)).stdout.strip_edges(), base + "/Child",
			"a bare relative node path resolves from cwn")

	var missing = run_text("node Missing", Sh.Context.new_ctx("missing", ctx))
	check(missing.exit_code != 0 and missing.stderr.contains("Node not found"), "an explicit missing node reports an error")
	check(not ctx.has_scope("Missing"), "an unresolvable bare name does not resolve")

	# Extensions classify before any tree lookup, so a resource path is never a node.
	check(ctx.has_scope("res://addons/addon_lib/gdsh/load.gd"), "a .gd path routes to the script command, not a node")
	# Classification is by extension, so this resolves before the file is known to exist.
	check(ctx.has_scope("boot.gdsh"), "a .gdsh path routes to the gdsh command, not a node")

	# Registered scopes are checked before bare resolution, so a node cannot shadow a command.
	var shadow = Node.new()
	shadow.name = "echo"
	fixture.add_child(shadow)
	equal(run_text("echo hi", Sh.Context.new_ctx("shadow", ctx)).stdout.strip_edges(), "hi",
			"a registered command is not shadowed by a node of the same name")

	# GDSh is a global class here, so a node with that name is genuinely ambiguous.
	var clash = Node.new()
	clash.name = "GDSh"
	fixture.add_child(clash)
	var ambiguous = run_text("GDSh", Sh.Context.new_ctx("ambiguous", ctx))
	check(ambiguous.exit_code != 0 and ambiguous.stderr.contains("both a global class and a node"),
			"a name matching both a class and a node reports the clash")

	root.remove_child(fixture)
	fixture.free()

## The script target: a global class name, a res:// path, or a path relative to cwd, with the
## subcommands routed at whatever resolved.
func _test_script_target():
	var target = FIXTURES + "method_target.gd"
	var ctx = session()

	# A .gd path classifies as a script before any tree lookup.
	check(ctx.has_scope(target), "a res:// script path resolves")
	equal(run_text(target + " get_path", Sh.Context.new_ctx("path", ctx)).stdout.strip_edges(), target,
			"get_path prints the resolved script's resource path")
	equal(run_text("script " + target + " get_path", Sh.Context.new_ctx("explicit", ctx)).stdout.strip_edges(), target,
			"the explicit script command resolves the same target")
	equal(run_text("script --path=" + target + " get_path", Sh.Context.new_ctx("flag", ctx)).stdout.strip_edges(), target,
			"--path= targets a script by path")

	# Relative to cwd, which the fixtures directory makes straightforward.
	var relative = Sh.Context.new_ctx("relative", ctx)
	relative.cwd = FIXTURES
	equal(run_text("method_target.gd get_path", relative).stdout.strip_edges(), target,
			"a relative script path resolves from cwd")

	# call reaches static methods and converts arguments through GDSh.Utils.Method.
	var called = run_text(target + " call add -- 3 4", Sh.Context.new_ctx("call", ctx))
	check(called.exit_code == 0 and called.stdout.strip_edges().ends_with("7"),
			"call runs a static method and converts args: " + called.stdout + called.stderr)
	var defaulted = run_text(target + " call add -- 3", Sh.Context.new_ctx("default", ctx))
	check(defaulted.exit_code == 0 and defaulted.stdout.strip_edges().ends_with("5"),
			"call uses a declared default: " + defaulted.stdout + defaulted.stderr)
	# greet is an instance method, so static-only filtering must reject it.
	var instance_method = run_text(target + " call greet -- world", Sh.Context.new_ctx("instance", ctx))
	check(instance_method.exit_code != 0, "call rejects an instance method on a script target")

	var listed = run_text(target + " list --methods", Sh.Context.new_ctx("list", ctx))
	check(listed.exit_code == 0 and listed.stdout.contains("add"), "list reports the script's methods: " + listed.stderr)
	var args_out = run_text(target + " args add", Sh.Context.new_ctx("args", ctx))
	check(args_out.exit_code == 0 and args_out.stdout.contains("a:"), "args lists a method's arguments: " + args_out.stderr)
	var text_result = run_text(target + " --text", Sh.Context.new_ctx("text", ctx))
	if load(target).has_source_code():
		check(text_result.exit_code == 0 and text_result.stdout.contains("static func add"), "--text writes the script source")
	else:
		check(text_result.exit_code != 0 and text_result.stderr.contains("source is unavailable"), "--text diagnoses stripped source in binary exports")

	# A global class name resolves through the class table rather than a path.
	check(ctx.has_scope("GDSh"), "a bare global class name resolves to the script command")
	# Nothing registered and not a class, path or node: still unrecognized.
	check(not ctx.has_scope("NotAClassOrNode"), "an unknown bare name still does not resolve")
	var missing = run_text("script res://addons/addon_lib/gdsh/missing_script.gd get_path",
			Sh.Context.new_ctx("missing", ctx))
	check(missing.exit_code != 0, "an unresolvable script target reports an error")

func _test_clear():
	var ctx = session()
	var missing = run_text("clear", Sh.Context.new_ctx("clear", ctx))
	check(missing.exit_code == 1 and missing.stderr.contains("no console"), "clear without a console fails")
	var calls = []
	ctx.host_data["clear_callback"] = func(_active, history):
		calls.append(history)
		return 3
	equal(run_text("clear --history", Sh.Context.new_ctx("clear", ctx)).exit_code, 3, "clear returns the callback status")
	equal(calls, [true], "clear passes the history flag to the host callback")
	var hosted = Sh.Console.new(ctx)
	hosted.set_context(ctx)
	check(ctx.host_data["clear_callback"].get_method() != "_clear_from_command", "console keeps a host clear callback")
	var plain = Sh.Console.new()
	var transcript = plain.create_output()
	_submit(plain, "echo visible")
	_submit(plain, "clear")
	equal(transcript.get_parsed_text(), "", "console default clear empties the transcript")
	check(not plain.command_history.is_empty(), "clear keeps history without --history")
	_submit(plain, "clear --history")
	check(plain.command_history.is_empty(), "clear --history empties console history")
	hosted.free()
	plain.free()

func _test_new_ctx():
	var missing = run_text("new_ctx", Sh.Context.new_ctx("new_ctx", session()))
	check(missing.exit_code == 1 and missing.stderr.contains("no console"), "new_ctx without a console fails")
	var console = Sh.Console.new()
	var built = []
	console.context_factory = func():
		built.append(session())
		return built.back()
	var original = console.context
	_submit(console, "x = 1")
	console.context.cwd = COMMANDS
	var result = _submit(console, "x = 2 && new_ctx && echo after; echo skipped")
	equal(result.exit_code, 0, "new_ctx succeeds")
	check(not result.stdout.contains("after") and not result.stdout.contains("skipped"), "new_ctx stops the rest of the submission")
	check(built.size() == 1 and console.context == built[0] and console.context != original, "new_ctx swaps in the factory context")
	check(not console.context.variables.has("$x") and console.context.cwd == "res://", "new_ctx drops session state")
	equal(_submit(console, "echo alive").stdout.strip_edges(), "alive", "submissions run on the new session")
	console.context_factory = Callable()
	equal(_submit(console, "false; new_ctx").exit_code, 0, "new_ctx status replaces the prior status")
	check(console.context != built[0] and built.size() == 1, "reset without a factory uses a bare context")
	var hosted_ctx = session()
	hosted_ctx.host_data["new_ctx_callback"] = func(_ctx): return 4
	var hosted = Sh.Console.new(hosted_ctx)
	equal(_submit(hosted, "new_ctx").exit_code, 4, "new_ctx returns the host callback status")
	check(hosted.context == hosted_ctx, "console keeps a host new_ctx callback")
	console.free()
	hosted.free()

func _test_value_conversion():
	var V = Sh.Utils.Value
	equal(V.convert("true", TYPE_BOOL), true, "string to bool")
	equal(V.convert("maybe", TYPE_BOOL), null, "invalid bool is null")
	equal(V.convert("12", TYPE_INT), 12, "string to int")
	equal(V.convert("abc", TYPE_INT), null, "invalid int is null")
	equal(V.convert("1.5", TYPE_FLOAT), 1.5, "string to float")
	equal(V.convert("name", TYPE_STRING_NAME), &"name", "string to StringName")
	equal(V.convert("(1, 2)", TYPE_VECTOR2), Vector2(1, 2), "tuple to Vector2")
	equal(V.convert("Vector3i(1, 2, 3)", TYPE_VECTOR3I), Vector3i(1, 2, 3), "prefixed tuple to Vector3i")
	equal(V.convert("#ff0000", TYPE_COLOR), Color.RED, "html string to Color")
	equal(V.convert("[1, 'a', true]", TYPE_ARRAY), [1, "a", true], "array literal")
	equal(V.convert("SIZE_EXPAND_FILL", TYPE_INT, "Control"), Control.SIZE_EXPAND_FILL, "class constant on base type")
	equal(V.convert("Control.SIZE_FILL", TYPE_INT, "Node"), Control.SIZE_FILL, "qualified class constant")
	equal(V.convert("Control.SizeFlags.SIZE_FILL", TYPE_INT, "Node"), Control.SIZE_FILL, "qualified enum constant")
	equal(V.convert(3, TYPE_INT), 3, "matching types pass through")
	equal(V.infer_type("42"), 42, "infer int")
	equal(V.infer_type("false"), false, "infer bool")
	equal(V.infer_type("word"), "word", "infer string")

func _test_method_call():
	var M = Sh.Utils.Method
	var methods = load(FIXTURES + "method_target.gd")
	var ctx = session()
	var outcome = M.call_method(ctx, methods, "add", ["3", "4"])
	check(outcome.ok and outcome.result == 7, "static call on a script converts string args: " + ctx.stderr)
	check(ctx.stdout.contains("Arg 'a' conversion"), "argument conversion is reported")
	equal(M.call_method(session(), methods, "add", [3]).result, 5, "declared default fills a trailing arg")
	ctx = session()
	check(not M.call_method(ctx, methods, "add", []).ok and ctx.stderr.contains("Arg count mismatch"), "missing required args fail")
	equal(M.call_method(session(), methods, "length_of", [], true).result, 0.0, "create_default_args fills required args")
	ctx = session()
	check(not M.call_method(ctx, methods, "length_of", ["oops"]).ok and ctx.stderr.contains("type mismatch"), "unconvertible args fail")
	ctx = session()
	check(not M.call_method(ctx, methods, "greet", ["x"]).ok and ctx.stderr.contains("instance method"), "instance method on a script fails")
	var instance = methods.new()
	equal(M.call_method(session(), instance, "greet", ["world"]).result, "hello world", "instance method on an object")
	equal(M.call_method(session(), instance, "add", [1, 1]).result, 2, "static method through an instance")
	var node = Node.new()
	check(M.call_method(session(), node, "set_name", ["probe_node"]).ok and node.name == &"probe_node", "engine method on a node converts String to StringName")
	node.free()
	ctx = session()
	check(not M.call_method(ctx, methods, "missing", []).ok and ctx.stderr.contains("not found"), "missing method fails")
	var provided = RefCounted.new()
	var filled = M.call_method(session(), methods, "identity", [], true, func(_class_name): return provided)
	check(filled.ok and filled.result == provided, "object_default fills object params")

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
	equal(Sh.Utils.color_text("[b]", Color.RED), "[color=ff0000][lb]b][/color]", "color_text escapes BBCode")
	var hooked = Sh.Context.new()
	check(Sh.Utils.file_paths(hooked).has("res://tests/gdsh/runtime_test.gd"), "file_paths walks res:// by default")
	hooked.host_data["file_paths"] = func(directories): return PackedStringArray(["dirs" if directories else "files"])
	equal(Array(Sh.Utils.file_paths(hooked, true)), ["dirs"], "file_paths uses the host hook")
	var changed = [0]
	hooked.host_data["filesystem_changed"] = func(): changed[0] += 1
	Sh.Utils.filesystem_changed(hooked)
	Sh.Utils.filesystem_changed(Sh.Context.new())
	equal(changed[0], 1, "filesystem_changed calls only the host hook")

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
	run_text('echo "[color=red]a[/color]" >"$OUT"', ctx)
	equal(_read(temp.path_join("space name.txt")), "a\n", "redirected output drops color markup")
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
	check(initial_help.contains("\n  builtins") and initial_help.contains("\n  hidden") and not initial_help.contains("\n  help"), "help lists hidden namespaces and omits non-discoverable builtins")
	check(not initial_help.contains("__function__") and not initial_help.contains("__ambiguous__"), "help excludes reserved internal scopes")
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
	_tree().root.add_child(edit)
	check(not syntax.highlight_globals, "global highlighting defaults off")
	_check_highlight(edit, "hidden echo hello", "hidden", palette.scope, "hidden parent highlighted")
	_check_highlight(edit, "hidden echo hello", "echo", palette.scope, "hidden command highlighted")
	_check_highlight(edit, "probe arg", "probe", palette.function_def, "function shadows command color")
	_check_highlight(edit, "@p arg", "@p", palette.alias, "context alias highlighted")
	_check_highlight(edit, "echo $KNOWN", "$KNOWN", palette.variable, "known variable")
	_check_highlight(edit, "echo $MISSING", "$MISSING", palette.unknown_variable, "unknown variable")
	_check_highlight(edit, "echo ${KNOWN}1", "${KNOWN}", palette.variable, "braced variable")
	_check_highlight(edit, "echo ${}", "${}", palette.unknown_variable, "empty braces color as one variable span")
	_check_highlight(edit, "echo ${", "${", palette.unknown_variable, "an opening brace colors as a variable")
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
	# In the editor, root is the editor window: leave it alone (the cap check is relative).
	if not Engine.is_editor_hint():
		_tree().root.size = Vector2i(640, 480)
	var console = Sh.Console.new()
	var selected_syntax = Sh.Console.Highlighter.new()
	console.set_highlighter(selected_syntax)
	_tree().root.add_child(console)
	check(console.input.syntax_highlighter == selected_syntax, "pre-tree highlighter selection persists")
	check(selected_syntax.context == console.context, "console binds highlighter context")
	console.input.text = "probe"
	equal(_highlight_color(console.input, 0), selected_syntax.palette.text, "unloaded command is plain")
	console.load(COMMANDS + "probe.gd")
	equal(_highlight_color(console.input, 0), selected_syntax.palette.scope, "loading commands refreshes highlighting")
	console.input.text = "$HIGHLIGHT_TEST"
	equal(_highlight_color(console.input, 0), selected_syntax.palette.unknown_variable, "undefined variable is unknown")
	_submit(console, "HIGHLIGHT_TEST=value")
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
	_submit(console, "true")
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

	var result = _submit(console, "X=one; echo $X")
	equal(result.stdout.strip_edges(), "one", "console execute returns its result context")
	equal(console.context.variables.get("$X"), "one", "console preserves variables in its main context")
	equal(submitted, ["X=one; echo $X"], "console emits submitted signal")
	equal(finished.size(), 1, "console emits finished signal")
	check(finished[0][1] == result, "finished signal carries the result context")
	_submit(console, "f(){echo persisted};alias @persist=f")
	equal(_submit(console, "@persist").stdout.strip_edges(), "persisted", "console preserves functions and aliases")
	_submit(console, "cd tests/gdsh/fixtures")
	check(console.context.cwd.ends_with("/tests/gdsh/fixtures"), "console preserves cwd in its main context")
	_submit(console, "cd res://")

	_submit(console, "false")
	equal(_submit(console, "echo $?").stdout.strip_edges(), "1", "console preserves status between submissions")
	var exit_result = _submit(console, "exit 7")
	equal(exit_result.exit_code, 7, "console result preserves exit status")
	check(not console.context.exit_requested, "exit does not stop the console session")
	equal(_submit(console, "echo alive").stdout.strip_edges(), "alive", "console remains usable after exit")

	_submit(console, "echo duplicate")
	_submit(console, "echo another")
	_submit(console, "echo duplicate")
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
	_submit(console, "echo visible")
	check(console.prompt_label.text == default_prompt, "logged default prompt retains its light-blue source markup")
	check(transcript.get_parsed_text().contains("Console $ echo visible"), "transcript echoes the prompt and command")
	check(transcript.get_parsed_text().contains("visible"), "transcript appends stdout")
	_submit(console, "unknown_console_command")
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
	equal(_submit(console, "echo newest wins").stdout.strip_edges(), "layered:newest wins", "newest console command layer wins")
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
	await _tree().process_frame
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
	if Engine.is_editor_hint():
		report.append("(skipped console input consumption in the editor: it injects real key and wheel events)")
	else:
		await _test_console_input_consumption(console, transcript)
	console.queue_free()


func _test_console_popup_navigation() -> void:
	var console = Sh.Console.new(session())
	_tree().root.add_child(console)
	console.size = Vector2(640, 400)
	var input = console.input
	var options = Sh.Options.new()
	for group in 3:
		options.add_separator("Group %d" % group)
		for index in 20:
			options.add_option("choice_%02d" % (group * 20 + index))
	input.completion_factory = func(text, context, caret):
		var request = FixedCompletion.new(text, context, caret)
		request.choices = options.get_options()
		return request
	await input.request_completion(true)
	input._timer.stop()
	input.grab_focus()
	var popup = input._popup
	# Reserve horizontal scrollbar space to exercise the reduced visible height.
	popup.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	for frame in 2: await _tree().process_frame
	var selectable:Array[int] = []
	for index in popup._items.item_count:
		if not popup._items.is_item_disabled(index):
			selectable.append(index)
	equal(popup._items.get_selected_items()[0], selectable[0], "popup initially skips the group heading")
	_check_popup_selection_visible(popup, "initial selection")
	check(popup.get_h_scroll_bar().visible, "popup exercises visibility with a horizontal scrollbar")
	var probe = InputProbe.new()
	_tree().root.add_child(probe)
	var key = InputEventKey.new()
	key.pressed = true
	var position = 0
	for direction in [1, -1]:
		key.keycode = KEY_DOWN if direction == 1 else KEY_UP
		for step in selectable.size() + 1:
			key.echo = step > 0
			if Engine.is_editor_hint():
				input._on_gui_input(key)
			else:
				Input.parse_input_event(key)
			position = posmod(position + direction, selectable.size())
			for frame in 2: await _tree().process_frame
			equal(popup._items.get_selected_items()[0], selectable[position], "arrow press/repeat advances past separators (%d, %d)" % [direction, step])
			_check_popup_selection_visible(popup, "arrow navigation (%d, %d)" % [direction, step])
	check(probe.events.is_empty(), "popup arrow presses and repeats remain consumed")
	probe.queue_free()

	# Already-visible rows should not move the viewport.
	popup.select_next()
	for frame in 2: await _tree().process_frame
	var previous_scroll = popup.scroll_vertical
	popup.select_previous()
	for frame in 2: await _tree().process_frame
	equal(popup.scroll_vertical, previous_scroll, "visible selection does not scroll unnecessarily")

	var submissions:Array = []
	var acceptances:Array = []
	input.submit_requested.connect(func(value): submissions.append(value))
	popup.choice_accepted.connect(func(choice, _data): acceptances.append(choice))
	for code in [KEY_ENTER, KEY_KP_ENTER, KEY_TAB]:
		key.keycode = code
		key.echo = true
		input._on_gui_input(key)
	check(submissions.is_empty() and acceptances.is_empty() and popup.visible, "echoed Enter and Tab do not submit or accept")

	# Wrap to the last choice, then rebuild while still overflowing.
	popup.select_previous()
	for frame in 2: await _tree().process_frame
	check(popup.scroll_vertical > 0, "wrapping up scrolls to the last choice")
	options.add_option("new choice")
	await input.request_completion(true)
	for frame in 2: await _tree().process_frame
	equal(popup._items.get_selected_items()[0], selectable[0], "rebuilt choices select the first enabled row")
	_check_popup_selection_visible(popup, "rebuilt selection after scrolling")

	# A delayed scroll must not affect a hidden popup.
	await input.request_completion(true)
	input._hide_completion()
	previous_scroll = popup.scroll_vertical
	for frame in 2: await _tree().process_frame
	check(not popup.visible and popup.scroll_vertical == previous_scroll, "pending visibility update leaves hidden popup alone")
	var history:Array = []
	input.history_requested.connect(func(direction): history.append(direction))
	for code in [KEY_UP, KEY_DOWN]:
		key.keycode = code
		key.echo = true
		input._on_gui_input(key)
	check(history.is_empty(), "echoed arrows do not navigate command history")
	for code in [KEY_UP, KEY_DOWN]:
		key.keycode = code
		key.echo = false
		input._on_gui_input(key)
	equal(history, [-1, 1], "initial arrows still navigate command history")
	console.queue_free()
	await _tree().process_frame


func _check_popup_selection_visible(popup, label:String) -> void:
	var row:Rect2 = popup._items.get_item_rect(popup._items.get_selected_items()[0])
	row.position += popup._items.global_position
	var panel:StyleBox = popup.get_theme_stylebox("panel")
	var top:float = popup.global_position.y + panel.get_margin(SIDE_TOP)
	var bottom:float = popup.global_position.y + popup.size.y - panel.get_margin(SIDE_BOTTOM)
	if popup.get_h_scroll_bar().visible:
		bottom -= popup.get_h_scroll_bar().size.y
	check(row.position.y >= top - 1.0 and row.end.y <= bottom + 1.0,
		"selected row is fully visible: %s (row %s, viewport %s..%s)" % [label, row, top, bottom])


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
	_tree().root.add_child(console)
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


func _test_console_node_completion() -> void:
	var fixture = Node.new()
	fixture.name = "GDShNodeCompletion"
	_tree().root.add_child(fixture)
	var alpha = Node.new()
	alpha.name = "Alpha"
	fixture.add_child(alpha)
	var beta = Node.new()
	beta.name = "Beta"
	alpha.add_child(beta)
	var internal = Node.new()
	internal.name = "Internal"
	alpha.add_child(internal, false, Node.INTERNAL_MODE_BACK)
	var leaf = Node.new()
	leaf.name = "Leaf"
	internal.add_child(leaf)
	var spaced = Node.new()
	spaced.name = "With Space"
	alpha.add_child(spaced)
	var deep = Node.new()
	deep.name = "Deep Space"
	spaced.add_child(deep)
	var ctx = session()
	ctx.cwn = str(fixture.get_path())
	var console = Sh.Console.new(ctx)
	_tree().root.add_child(console)
	for prefix in ["cn ", "node ", ""]:
		if not prefix.is_empty():
			await _accept_console_choice(console.input, prefix + "Al", "Alpha", prefix + "Alpha/")
		await _accept_console_choice(console.input, prefix + "Alpha/", "Beta", prefix + "Alpha/Beta/")
		await _accept_console_choice(console.input, prefix + "Alpha/B", "Beta", prefix + "Alpha/Beta/")
		var internal_prefix = "cn -i " if prefix == "cn " else prefix
		await _accept_console_choice(console.input, internal_prefix + "Alpha/I", "Internal", internal_prefix + "Alpha/Internal/")
		await _accept_console_choice(console.input, prefix + "Alpha/Internal/", "Leaf", prefix + "Alpha/Internal/Leaf/")
		await _accept_console_choice(console.input, prefix + "./Alpha/B", "Beta", prefix + "./Alpha/Beta/")
		await _accept_console_choice(console.input, prefix + ctx.cwn + "/Alpha/B", "Beta", prefix + ctx.cwn + "/Alpha/Beta/")
		await _accept_console_choice(console.input, prefix + "Alpha/", "..", prefix + "Alpha/../")
		if not prefix.is_empty():
			await _accept_console_choice(console.input, prefix + "/", "root", prefix + "/root/")
		await _accept_console_choice(console.input, prefix + "/root/", str(fixture.name), prefix + str(fixture.get_path()) + "/")
		await _accept_console_choice(console.input, prefix + '"Alpha/With', "With Space", prefix + '"Alpha/With Space/"')
		await _accept_console_choice(console.input, prefix + '"Alpha/With Space/"', "Deep Space", prefix + '"Alpha/With Space/Deep Space/"')
		await _accept_console_choice(console.input, "echo before; " + prefix + "Alpha/B", "Beta", "echo before; " + prefix + "Alpha/Beta/", " ; echo after")
	await _accept_console_choice(console.input, "cn --int", "--internal", "cn --internal ")
	await _accept_console_choice(console.input, "cn --internal Alpha/I", "Internal", "cn --internal Alpha/Internal/")
	console.input.text = "cn Alpha/I"
	console.input.set_caret_column(console.input.text.length())
	await console.input.request_completion(true)
	check(not console.input._popup._choices.has("Internal"), "cn popup hides internal children by default")
	console.free()
	fixture.free()


func _test_console_mixed_path_completion() -> void:
	var fixture_path = "user://gdsh-mixed-completion-%s" % Time.get_ticks_usec()
	equal(DirAccess.make_dir_recursive_absolute(fixture_path + "/Alpha"), OK, "create mixed path fixture")
	for name in ["file.gdsh", "Shared", "With Space.gdsh", "Alpha/child.txt"]:
		var file = FileAccess.open(fixture_path.path_join(name), FileAccess.WRITE)
		file.store_string("echo fixture")
		file.close()
	var fixture = Node.new()
	fixture.name = "GDShMixedCompletion"
	_tree().root.add_child(fixture)
	for name in ["Alpha", "Shared", "NodeOnly"]:
		var child = Node.new()
		child.name = name
		fixture.add_child(child)
	var beta = Node.new()
	beta.name = "Beta"
	fixture.get_node("Alpha").add_child(beta)
	var ctx = session()
	ctx.cwd = fixture_path
	ctx.cwn = str(fixture.get_path())
	var choices = complete("./", ctx)
	var names = choices.keys()
	var separator = -1
	for i in names.size():
		if Sh.Options.Keys.get_seperator(str(names[i])) != null:
			separator = i
	check(separator >= 0, "mixed completion has a node separator")
	check(names.find("file.gdsh") >= 0 and names.find("file.gdsh") < separator, "files precede the node separator")
	check(names.find("Alpha") >= 0 and names.find("Alpha") < separator, "directories precede the node separator")
	check(names.find("NodeOnly") > separator, "nodes follow the separator")
	check(names.find("Alpha [node]") > separator and names.find("Shared [node]") > separator, "same-name files and nodes both survive")
	check(not complete("node ./", ctx).has("file.gdsh"), "explicit node completion excludes files")
	check(complete("cn ", ctx).has("NodeOnly"), "cn offers nodes immediately")
	check(complete("node ", ctx).has("NodeOnly"), "node offers nodes immediately")
	for text in ["", "No", "NodeOnly"]:
		check(not complete(text, ctx).has("NodeOnly"), "command position waits for a path prefix: " + text)
	var console = Sh.Console.new(ctx)
	_tree().root.add_child(console)
	console.input.text = "./"
	console.input.set_caret_column(2)
	await console.input.request_completion(true)
	var popup = console.input._popup
	check(popup._choices.find("file.gdsh") < popup._choices.find("NodeOnly"), "popup preserves files before nodes")
	await _accept_console_choice(console.input, "./", "file.gdsh", "./file.gdsh ")
	await _accept_console_choice(console.input, "./", "Shared", "./Shared ")
	await _accept_console_choice(console.input, "./", "Shared [node]", "./Shared/")
	await _accept_console_choice(console.input, "./Al", "Alpha", "./Alpha/")
	await _accept_console_choice(console.input, "./Al", "Alpha [node]", "./Alpha/")
	await _accept_console_choice(console.input, "./Alpha/", "child.txt", "./Alpha/child.txt ")
	await _accept_console_choice(console.input, "./Alpha/", "Beta", "./Alpha/Beta/")
	await _accept_console_choice(console.input, './With', "With Space.gdsh", '"./With Space.gdsh" ')
	await _accept_console_choice(console.input, "echo before; ./fi", "file.gdsh", "echo before; ./file.gdsh ", "; echo after")
	ctx.cwd = fixture_path + "/Alpha"
	ctx.cwn = str(fixture.get_node("Alpha").get_path())
	await _accept_console_choice(console.input, "../", "file.gdsh", "../file.gdsh ")
	await _accept_console_choice(console.input, "../", "NodeOnly", "../NodeOnly/")
	ctx.cwd = FIXTURES
	choices = complete("./", ctx)
	check(choices.has("method_target.gd"), "relative path completion preserves script names in binary exports")
	ctx.cwd = "user://gdsh-missing-completion-directory"
	check(complete("./", ctx).has("Beta"), "nodes remain when cwd is missing")
	ctx.scopes["./"] = {"script": preload("res://addons/addon_lib/gdsh/builtins/echo/echo.gd")}
	check(not complete("./", ctx).has("Beta"), "registered path commands retain their own completion")
	console.free()
	fixture.free()
	for path in ["file.gdsh", "Shared", "With Space.gdsh", "Alpha/child.txt", "Alpha", ""]:
		equal(DirAccess.remove_absolute(fixture_path.path_join(path)), OK, "remove mixed completion fixture")


func _test_console_input_consumption(console, transcript:RichTextLabel) -> void:
	var probe = InputProbe.new()
	_tree().root.add_child(probe)
	console.size = Vector2(640, 400)
	console.input.release_focus()
	var baseline_key = InputEventKey.new()
	baseline_key.keycode = KEY_F9
	baseline_key.pressed = true
	Input.parse_input_event(baseline_key)
	await _tree().process_frame
	check(probe.events.size() == 1, "input probe receives an unhandled key without console focus")
	probe.events.clear()
	console.input.grab_focus()
	await _tree().process_frame
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
		await _tree().process_frame
	check(probe.events.is_empty(), "focused console consumes key presses, releases, and repeats")
	console.input.text = ""
	var typed_key = InputEventKey.new()
	typed_key.keycode = KEY_X
	typed_key.unicode = "x".unicode_at(0)
	typed_key.pressed = true
	Input.parse_input_event(typed_key)
	await _tree().process_frame
	equal(console.input.text, "x", "consumed keyboard input still edits the focused console")
	check(probe.events.is_empty(), "typed console input remains consumed")

	console.input.release_focus()
	transcript.clear()
	for index in 80:
		transcript.add_text("line %d\n" % index)
	await _tree().process_frame
	var baseline_wheel = InputEventMouseButton.new()
	baseline_wheel.position = Vector2(639, 479)
	baseline_wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	baseline_wheel.pressed = true
	Input.parse_input_event(baseline_wheel)
	await _tree().process_frame
	check(probe.events.size() == 1, "input probe receives a wheel event outside the console")
	probe.events.clear()
	transcript.scroll_to_line(0)
	await _tree().process_frame
	var initial_scroll = transcript.get_v_scroll_bar().value
	var scroll_inside = InputEventMouseButton.new()
	scroll_inside.position = transcript.global_position + Vector2(4, 4)
	scroll_inside.button_index = MOUSE_BUTTON_WHEEL_DOWN
	scroll_inside.pressed = true
	Input.parse_input_event(scroll_inside)
	await _tree().process_frame
	check(transcript.get_v_scroll_bar().value > initial_scroll, "consumed wheel events still scroll the transcript")
	check(probe.events.is_empty(), "scrolling transcript does not pass wheel events to the game")
	for at_end in [false, true]:
		transcript.scroll_to_line(transcript.get_line_count() - 1 if at_end else 0)
		await _tree().process_frame
		var wheel = InputEventMouseButton.new()
		wheel.position = transcript.global_position + Vector2(4, 4)
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN if at_end else MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		Input.parse_input_event(wheel)
		await _tree().process_frame
	check(probe.events.is_empty(), "transcript consumes wheel events at both scroll limits")
	var pan = InputEventPanGesture.new()
	pan.position = transcript.global_position + Vector2(4, 4)
	pan.delta = Vector2(0, 1)
	Input.parse_input_event(pan)
	await _tree().process_frame
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


## Real node/script targets exercise routing, inheritance and reflection together.
func _test_target_members():
	var target_script = load(FIXTURES + "node_target.gd")
	var node = target_script.new()
	node.name = "GDShMemberFixture"
	_tree().root.add_child(node)
	var bare = Node.new()
	bare.name = "Bare"
	node.add_child(bare)
	var ctx = session()
	ctx.cwn = str(node.get_path())
	var node_head = "node " + str(node.get_path())
	var script_head = "script " + FIXTURES + "node_target.gd"
	for head in [node_head, script_head]:
		var own = complete(head + " call ", ctx)
		check(own.has("own_static"), "target completes own static method: " + head)
		check(not own.has("base_static") and not own.has("get_instance_id"), "default method surface excludes inheritance: " + head)
		var inherited = complete(head + " call --inherited ", ctx)
		check(inherited.has("base_static") and not inherited.has("get_instance_id"), "--inherited adds scripts only: " + head)
		var called = run_text(head + " call --inherited base_static -- 8", Sh.Context.new_ctx("inherit", ctx))
		check(called.exit_code == 0 and called.stdout.strip_edges().ends_with("16"), "inherited static call: " + called.stderr)
		check(run_text(head + " call base_static", Sh.Context.new_ctx("inherit", ctx)).exit_code != 0, "inherited calls require selector: " + head)
		var listed = run_text(head + " list --methods", Sh.Context.new_ctx("list", ctx))
		check(listed.exit_code == 0 and listed.stdout.contains("own_method") and not listed.stdout.contains("base_method"), "list own methods: " + head)
		check(not listed.stdout.contains("_secret"), "list hides private methods: " + head)
		listed = run_text(head + " list --methods --inherited", Sh.Context.new_ctx("list", ctx))
		check(listed.stdout.contains("base_method") and listed.stdout.contains("own_method") and not listed.stdout.contains("get_instance_id"), "list script inheritance: " + head)
		listed = run_text(head + " list --methods --engine", Sh.Context.new_ctx("list", ctx))
		check(listed.stdout.contains("get_instance_id") and listed.stdout.contains("own_method"), "list engine surface: " + head)
		listed = run_text(head + " list --methods --private", Sh.Context.new_ctx("list", ctx))
		check(listed.stdout.contains("_secret"), "list --private: " + head)
		var args_result = run_text(head + " args base_method", Sh.Context.new_ctx("args", ctx))
		check(args_result.exit_code != 0, "args default excludes inherited method: " + head)
		args_result = run_text(head + " args --inherited base_method", Sh.Context.new_ctx("args", ctx))
		check(args_result.exit_code == 0 and args_result.stdout.contains("value:"), "args script inheritance: " + head)
		check(not complete(head + " args ", ctx).has("_secret"), "args hides private methods: " + head)
		check(complete(head + " args --private ", ctx).has("_secret"), "args completes private methods with flag: " + head)
		check(run_text(head + " args _secret", Sh.Context.new_ctx("args", ctx)).exit_code != 0, "args requires --private: " + head)
		check(run_text(head + " args --private _secret", Sh.Context.new_ctx("args", ctx)).exit_code == 0, "args --private succeeds: " + head)
		listed = run_text(head + " list --properties", Sh.Context.new_ctx("props", ctx))
		check(listed.stdout.contains("own_value") and not listed.stdout.contains("base_value") and not listed.stdout.contains("_private_value"), "properties respect default selection: " + head)
		check(not listed.stdout.contains("Target Category") and not listed.stdout.contains("Target Group"), "properties omit category/group markers: " + head)
		listed = run_text(head + " list --properties --inherited --private", Sh.Context.new_ctx("props", ctx))
		check(listed.stdout.contains("base_value") and listed.stdout.contains("_private_value"), "properties respect inherited/private flags: " + head)
		listed = run_text(head + " list --signals --inherited", Sh.Context.new_ctx("signals", ctx))
		check(listed.stdout.contains("own_signal") and listed.stdout.contains("base_signal") and not listed.stdout.contains("_private_signal"), "signals use same inheritance/private rules: " + head)
		listed = run_text(head + " list --constants --inherited", Sh.Context.new_ctx("constants", ctx))
		check(listed.stdout.contains("OWN_VALUE") and listed.stdout.contains("BASE_VALUE") and not listed.stdout.contains("_PRIVATE_VALUE"), "constants include base and own declarations: " + head)
		listed = run_text(head + " list --enums", Sh.Context.new_ctx("enum", ctx))
		check(listed.exit_code == 0 and listed.stdout.contains("State"), "script enums need no inheritance flag: " + head)

	check(not complete(script_head + " call --engine ", ctx).has("own_method"), "script call remains static-only with --engine")
	check(complete(script_head + " args ", ctx).has("own_method"), "script args can inspect instance signatures")
	check(complete(node_head + " call ", ctx).has("own_method"), "node completes instance methods")
	check(not complete(node_head + " call ", ctx).has("_secret"), "node call hides private methods")
	check(complete(node_head + " call --private ", ctx).has("_secret"), "node call --private completion")
	check(run_text(node_head + " call _secret", Sh.Context.new_ctx("private", ctx)).exit_code != 0, "explicit private calls still require flag")
	var result = run_text(node_head + " call --private _secret", Sh.Context.new_ctx("private", ctx))
	check(result.exit_code == 0 and result.stdout.strip_edges().ends_with("9"), "private call with flag")
	result = run_text(node_head + " call own_method -- 4", Sh.Context.new_ctx("instance", ctx))
	check(result.exit_code == 0 and result.stdout.strip_edges().ends_with("10"), "live instance call uses its state")
	result = run_text(node_head + " call --inherited describe -- 11", Sh.Context.new_ctx("override", ctx))
	check(result.exit_code == 0 and result.stdout.strip_edges().ends_with("child:11"), "derived method override wins")
	result = run_text(node_head + " call --inherited describe", Sh.Context.new_ctx("override", ctx))
	check(result.exit_code == 0 and result.stdout.strip_edges().ends_with("child:200"), "derived method default overrides base metadata")
	check(run_text(node_head + " call get_instance_id", Sh.Context.new_ctx("engine", ctx)).exit_code != 0, "engine call requires selector")
	result = run_text(node_head + " call --engine get_instance_id", Sh.Context.new_ctx("engine", ctx))
	check(result.exit_code == 0 and result.stdout.contains(str(node.get_instance_id())), "engine method runs on live node")
	result = run_text(node_head + " args --engine call", Sh.Context.new_ctx("varargs", ctx))
	check(result.exit_code == 0 and result.stdout.contains("...args"), "args describes engine varargs")
	var choices = complete(node_head + " call --engine ", ctx)
	check(choices.has("call") and choices.call.get(Sh.Options.Keys.METADATA, {}).get(Sh.Options.Keys.ARG_COUNT) == -1,
			"varargs completion has unbounded arg count")
	check(choices.call.get(Sh.Options.Keys.METADATA, {}).get(Sh.Options.Keys.ADD_ARGS, false), "varargs completion suggests payload")
	result = run_text(node_head + " call --engine call -- set_meta probe extra", Sh.Context.new_ctx("varargs", ctx))
	check(result.exit_code == 0 and node.get_meta("probe", "") == "extra", "engine varargs forward extra payload")
	result = run_text(node_head + " call --engine call", Sh.Context.new_ctx("varargs", ctx))
	check(result.exit_code != 0 and result.stderr.contains("Arg count mismatch"), "varargs enforce required fixed parameters")
	result = run_text(node_head + " list --properties --engine", Sh.Context.new_ctx("dynamic", ctx))
	check(result.stdout.contains("dynamic_value") and result.stdout.contains("process_mode") and not result.stdout.contains("Live Group"), "live property surface includes dynamic/engine data and omits groups")
	equal(run_text(node_head + " get_path", Sh.Context.new_ctx("path", ctx)).stdout.strip_edges(), str(node.get_path()), "node get_path")
	equal(run_text("Bare get_path", Sh.Context.new_ctx("relative", ctx)).stdout.strip_edges(), str(bare.get_path()), "bare relative node routes subcommands")
	equal(run_text("node ./Bare get_path", Sh.Context.new_ctx("relative", ctx)).stdout.strip_edges(), str(bare.get_path()), "explicit node preserves dot path segments")
	equal(run_text("node Bare/.. get_path", Sh.Context.new_ctx("relative", ctx)).stdout.strip_edges(), str(node.get_path()), "explicit node resolves parent segments")
	check(not complete("node Bare call ", ctx).has("get_instance_id"), "scriptless node hides engine methods by default")
	check(complete("node Bare call --engine ", ctx).has("get_instance_id"), "scriptless node completes engine methods")
	check(run_text("node Bare call --engine get_instance_id", Sh.Context.new_ctx("bare", ctx)).exit_code == 0, "scriptless node calls engine methods")
	result = run_text("node Missing get_path", Sh.Context.new_ctx("missing", ctx))
	check(result.exit_code != 0, "missing node subcommands fail cleanly")
	check(run_text("gdsh --help", Sh.Context.new_ctx("help", ctx)).exit_code == 0, "gdsh --help is not consumed as a filename")
	result = run_text("node --help", Sh.Context.new_ctx("help", ctx))
	check(result.exit_code == 0 and result.stdout.contains("get_path"), "node --help lists shared commands")
	for subcommand in ["call", "list", "args", "get_path"]:
		check(complete(node_head + " ", ctx).has(subcommand), "node completes " + subcommand)
	node.free()


func _test_script_access():
	var ctx = session()
	var path = FIXTURES + "dotted.gd.folder/target file.gd"
	var script = load(path)
	ctx.cwd = FIXTURES
	var paths = [path, "dotted.gd.folder/target file.gd", "./dotted.gd.folder/target file.gd"]
	# Packed resources do not have OS paths. Source runs also exercise localization.
	var absolute_path = ProjectSettings.globalize_path(path)
	if absolute_path.is_absolute_path():
		paths.append(absolute_path)
	for base in ["GDShAccessFixture"] + paths:
		for suffix in ["", ".Inner", ".Inner.Nested", ".Inherited", ".Alias"]:
			var expected = {"": "7", ".Inner": "42", ".Inner.Nested": "84", ".Inherited": "21", ".Alias": "21"}[suffix]
			for head in ['script "' + base + suffix + '"', '"' + base + suffix + '"']:
				var result = run_text(head + " call answer", Sh.Context.new_ctx("access", ctx))
				check(result.exit_code == 0 and result.stdout.strip_edges().ends_with(expected), "member target " + head + ": " + result.stderr)
	var user_path = "user://gdsh_access_external.gd"
	_write_file(user_path, "extends RefCounted\nclass Inner:\n\tstatic func answer(): return 63\n")
	for user_target in [user_path, ProjectSettings.globalize_path(user_path)]:
		var result = run_text('"' + user_target + '.Inner" call answer', Sh.Context.new_ctx("external", ctx))
		check(result.exit_code == 0 and result.stdout.strip_edges().ends_with("63"), "user/external script members: " + user_target + ": " + result.stderr)
	DirAccess.remove_absolute(user_path)
	for head in ['script --class=GDShAccessFixture.Inner', 'script --path="' + path + '.Inner"',
			'echo "' + path + '.Inner" | script']:
		var result = run_text(head + " call answer", Sh.Context.new_ctx("selectors", ctx))
		check(result.exit_code == 0 and result.stdout.strip_edges().ends_with("42"), "selector/piped members: " + head + ": " + result.stderr)
	for suffix in [".Missing", ".Inner.Missing", ".Scalar", ".Scalar.Inner", ".Inner..Nested", "."]:
		var result = run_text("script GDShAccessFixture" + suffix + " call answer", Sh.Context.new_ctx("invalid", ctx))
		check(result.exit_code != 0 and result.stderr.contains("Could not resolve script target"), "invalid chain fails: " + suffix)
	check(run_text("script GDShAccessFixture.Missing", Sh.Context.new_ctx("invalid", ctx)).exit_code != 0, "invalid target fails without a subcommand")
	for row in [
		["script GDShAccessFixture.", "Inner", "GDShAccessFixture.Inner"],
		["GDShAccessFixture.In", "Inner", "GDShAccessFixture.Inner"],
		["GDShAccessFixture.Inner.N", "Nested", "GDShAccessFixture.Inner.Nested"],
		['script "' + path + '.In"', "Inner", '"' + path + '.Inner"'],
		['"' + path + '.In', "Inner", '"' + path + '.Inner"'],
		["script --class=GDShAccessFixture.In", "Inner", "--class=GDShAccessFixture.Inner"],
		['script --path="' + path + '.In"', "Inner", '--path="' + path + '.Inner"'],
	]:
		var choices = complete(row[0], ctx)
		check(choices.has(row[1]), "member completion " + row[0] + ": " + str(choices.keys()))
		if choices.has(row[1]):
			equal(choices[row[1]][Sh.Options.Keys.METADATA][Sh.Options.Keys.INSERT], row[2], "completion preserves target prefix")
	check(complete("GDShAccessFixture.Inner ca", ctx).has("call"), "partial subcommand completion after inner target")
	check(complete('script "' + path + '.Inner" li', ctx).has("list"), "partial subcommand after quoted inner target")
	check(not complete("GDShAccessFixture..", ctx).has("Inner"), "completion rejects empty member segments")
	check(not complete("GDShAccessFixture.", ctx).has("Scalar"), "member completion excludes scalar constants")
	check(complete("GDShAccessFixture.", ctx).has("Inherited"), "member completion includes inherited constants")
	check(complete("GDShAccessFixture.Inner call ", ctx).has("answer"), "resolved members route method completion")
	script.calls = 0
	complete("GDShAccessFixture.", ctx)
	equal(script.calls, 0, "member completion never executes methods")
	ctx.host_data["current_script"] = func(): return script
	check(run_text("script call answer", Sh.Context.new_ctx("no implicit", ctx)).exit_code != 0, "script ignores legacy current_script hook")
	check(not ctx.has_scope("script.Inner"), "script.Inner is no longer a core editor alias")
	equal(run_text("script", Sh.Context.new_ctx("help", ctx)).exit_code, 0, "targetless script prints help")
	check(complete("script ", ctx).has("GDShAccessFixture"), "runtime script target completion lists global classes")
	ctx.host_data["script_targets"] = func(): return PackedStringArray(["GDShAccessFixture", "NoLongerAClass"])
	var choices = complete("script ", ctx)
	check(choices.has("GDShAccessFixture") and not choices.has("NoLongerAClass") and not choices.has("GDShAccessAbstractFixture"), "host suggestions filter to valid registered classes")
	check(complete("script GDShAcc", ctx).has("GDShAccessFixture"), "partial target uses registered suggestions")
	check(complete("script --class=", ctx).has("GDShAccessAbstractFixture"), "--class completion stays unrestricted")
	check(not complete("", ctx).has("GDShAccessFixture"), "registered script suggestions do not enter root completion")
	ctx.host_data["script_targets"] = func(): return PackedStringArray()
	check(run_text("GDShAccessFixture.Inner call answer", Sh.Context.new_ctx("unregistered", ctx)).exit_code == 0, "registry never restricts execution")
	var old = ctx.get_scope("echo")
	ctx.scopes[path + ".Inner"] = old
	equal(run_text('"' + path + '.Inner" shadow', Sh.Context.new_ctx("precedence", ctx)).stdout.strip_edges(), "shadow", "exact registered commands beat bare script members")


func _test_pwn():
	var ctx = session()
	equal(run_text("pwn", Sh.Context.new_ctx("pwn", ctx)).stdout, "/root\n", "pwn default")
	var node = Node.new()
	node.name = "GDShPwnFixture"
	_tree().root.add_child(node)
	var path = str(node.get_path())
	run_text("cn " + path, ctx)
	equal(run_text("pwn", Sh.Context.new_ctx("pwn", ctx)).stdout, path + "\n", "pwn follows cn and child inheritance")
	equal(run_text("(cn /root; pwn); pwn", Sh.Context.new_ctx("subshell", ctx)).stdout.strip_edges(), "/root\n" + path, "subshell pwn does not change parent cwn")
	node.free()
	equal(run_text("builtins pwn", Sh.Context.new_ctx("stale", ctx)).stdout, path + "\n", "pwn prints stale stored path without fallback")
	check(run_text("pwn extra", Sh.Context.new_ctx("args", ctx)).exit_code != 0, "pwn rejects arguments")
	check(not complete("", ctx).has("pwn"), "pwn remains hidden from root completion")


func _test_list_global():
	var ctx = session()
	for flags in ["--name=GDShAccessFixture", "--name=GDShAccessF*", "--name=*AccessFixture", "--name=*AccessF*", "--name=GDShAccessFixture --tool", "--name=GDShAccessFixture --base=RefCounted"]:
		var result = run_text("script list_global " + flags, Sh.Context.new_ctx("global", ctx))
		check(result.exit_code == 0 and result.stdout.contains("GDShAccessFixture"), "global listing filters " + flags)
	for flags in ["--name=NotAClass", "--name=GDShAccessFixture --abstract", "--name=GDShAccessFixture --lang=CSharp", "--name=GDShAccessFixture --base=Node"]:
		var result = run_text("script list_global " + flags, Sh.Context.new_ctx("empty", ctx))
		check(result.exit_code == 0 and result.stdout.contains("No classes to show"), "empty global listing " + flags)
	var result = run_text("script list_global --abstract --name=GDShAccessAbstractFixture", Sh.Context.new_ctx("abstract", ctx))
	check(result.exit_code == 0 and result.stdout.contains("GDShAccessAbstractFixture"), "abstract class listing")
	check(complete("script ", ctx).has("list_global"), "script exposes list_global without a target")
	check(not complete("node /root ", ctx).has("list_global"), "node does not expose list_global")
