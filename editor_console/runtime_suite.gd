extends RefCounted
## Editor Console runtime checks, driven by runtime_test.gd (headless and editor console `test`).
const Sh = preload("res://addons/addon_lib/gdsh/gdsh.gd")
const Adapter = preload("res://addons/editor_console/src/utils/os_adapter.gd")
var checks:int = 0
var failures:int = 0
var report:Array[String] = []
var _ctx:Sh.Context

func check(value:bool, label:String):
	checks += 1
	if not value:
		failures += 1
		report.append("FAIL: " + label)

func run_sync():
	_check_scripts("res://addons/editor_console")
	var defaults = load("res://addons/editor_console/src/default_commands/default.gd")
	var ctx = Sh.Context.new()
	ctx.scopes.merge(defaults.register_scopes())
	ctx.scopes_hidden.merge(defaults.register_hidden_scopes(), true)
	ctx.collect_raw_commands()
	check("os" in ctx.raw_commands, "os declares raw arguments")
	var routed = Sh.Context.new_ctx("routed os", ctx)
	Sh.Execute.execute_command_multiline("misc editor_console os printf routed", routed)
	check(routed.exit_code != 0 and "takes raw arguments" in routed.stderr, "routed os reports raw usage: " + routed.stderr)
	ctx.variables["$value"] = "hello $missing; echo wrong"
	check(Adapter.expand("echo $$HOME", ctx).text == "echo $HOME", "shell variable passthrough")
	check(Adapter.expand("echo '$$HOME'", ctx).text == "echo '$$HOME'", "single quotes stay literal")
	check(Adapter.expand('echo "$$HOME"', ctx).text == 'echo "$HOME"', "double-quoted shell variable")
	check(Adapter.expand("echo $$(printf shell)", ctx).text == "echo $(printf shell)", "shell substitution passthrough")
	check(Adapter.expand("echo $unknown", ctx).text == "echo ''", "unknown GDSh variable is empty")
	check(Adapter.expand("echo $(echo gdsh)", ctx).text == "echo 'gdsh'", "GDSh substitution")
	check(Adapter.expand("echo $value", ctx).text == "echo 'hello ; echo wrong'", "expanded values are shell quoted")
	check(ctx.scopes_hidden.has("cat") and ctx.scopes_hidden.has("utils") and ctx.scopes_hidden.has("os") and not ctx.scopes_hidden.has("manifest"), "hidden scopes include gdsh_lib utils and editor commands")
	var scene_choices = Sh.Completion.new("editor scene ", ctx).get_completions()
	check(ctx.scopes.has("tree") and scene_choices.has("root") and scene_choices.has("select") and not scene_choices.has("nodes"), "tree is top-level; editor scene keeps its own commands: " + str(scene_choices.keys()))
	var editor_choices = Sh.Completion.new("editor ", ctx).get_completions()
	check(editor_choices.has("undo") and editor_choices.has("redo"), "editor completes undo and redo")
	# Callable: input that never pauses returns without await, hidden from the coroutine check.
	var bridged = Callable(EditorConsoleSingleton.ConsoleBridge, "_capture").call('echo "[color=red]a[/color]"', ctx)
	check(bridged.stdout.strip_edges() == "a", "bridge returns plain text: " + bridged.stdout)
	for command in ["utils count", "count", "builtins echo hello", "hidden builtins echo hello", "echo hello"]:
		var result = Sh.Context.new_ctx("test", ctx)
		result.stdin = "one\ntwo\n"
		Sh.Execute.execute_command_multiline(command, result)
		check(result.exit_code == 0, "command: " + command + " " + result.stderr)
	check(not Sh.Completion.new("", ctx).get_completions().has("count"), "editor utility hidden at root")
	var hidden_choices = Sh.Completion.new("hidden ", ctx).get_completions()
	check(hidden_choices.has("builtins") and hidden_choices.has("utils"), "hidden completes namespaces")
	for name in ["count", "echo", "os", "class", "clear"]:
		check(not hidden_choices.has(name), "hidden omits non-discoverable " + name)
	check(Sh.Completion.new("misc editor_console ", ctx).get_completions().has("os"), "editor utility namespace completion")
	check(Sh.Completion.new("utils ", ctx).get_completions().has("count"), "utils namespace completion")
	if OS.get_name() != "Windows":
		for command in ["os printf 'one\\ntwo\\n' | count", "os printf '%s' $$HOME", "os printf '%s' $$(printf shell)"]:
			var result = Sh.Context.new_ctx("OS", ctx)
			Sh.Execute.execute_command_multiline(command, result)
			check(result.exit_code == 0 and not result.stdout.is_empty(), command + ": " + result.stderr)
		var result = Sh.Context.new_ctx("status", ctx)
		Sh.Execute.execute_command_multiline("os exit 7", result)
		check(result.exit_code == 7, "OS status propagates")
	_test_editor_behavior(ctx)
	_ctx = ctx

## Prompt path completion waits on the completion popup; headless only.
func run_frames():
	await _test_prompt_completion(_ctx)

func finish() -> Array[String]:
	report.append("Editor Console: %d checks, %d failures" % [checks, failures])
	return report

## The running tree: the headless runner's SceneTree or the editor's.
func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

func _check_scripts(directory:String):
	for file in DirAccess.get_files_at(directory):
		if file.ends_with(".gd"):
			var script = load(directory.path_join(file))
			# can_instantiate() is false for non-@tool scripts while scripting is disabled (editor).
			var checkable = script != null and (script.is_tool() or not Engine.is_editor_hint())
			check(script != null and (not checkable or script.can_instantiate()), "parse " + directory.path_join(file))
	for child in DirAccess.get_directories_at(directory):
		if child.begins_with(".") or child == "export_ignore": continue
		_check_scripts(directory.path_join(child))

func _result(text:String, ctx:Sh.Context) -> Sh.Context:
	# Callable: input that never pauses returns without await, hidden from the coroutine check.
	return Callable(Sh.Execute, "execute_command_multiline").call(text, Sh.Context.new_ctx("submission", ctx))

func _test_editor_behavior(ctx:Sh.Context):
	EditorConsoleSingleton.UtilsRemote.UClassDetail._build_global_class_registry()
	ctx.scope_resolver = EditorConsoleSingleton._resolve_editor_scope
	for text in ["EditorConsoleMigrationFixture call greeting -- world", "global EditorConsoleMigrationFixture call greeting -- world", "EditorConsoleMigrationFixture.Inner call answer"]:
		var result = _result(text, ctx)
		check(result.exit_code == 0 and ("hello world" in result.stdout or "42" in result.stdout), "global call: " + text + ": " + result.stderr)
	check(Sh.Completion.new("EditorConsoleMigrationFixture call ", ctx).get_completions().has("greeting"), "bare global method completion")
	check(Sh.Completion.new("EditorConsoleMigrationFixture.Inner call ", ctx).get_completions().has("answer"), "member access completion")
	var converted_call = _result("EditorConsoleMigrationFixture call add -- 3", ctx)
	check(converted_call.exit_code == 0 and "Arg 'a' conversion" in converted_call.stdout and converted_call.stdout.strip_edges().ends_with("5"), "call converts args and uses declared defaults: " + converted_call.stdout + converted_call.stderr)
	var default_call = _result("EditorConsoleMigrationFixture call --default add", ctx)
	check(default_call.exit_code == 0 and default_call.stdout.strip_edges().ends_with("2"), "call --default creates missing args: " + default_call.stdout + default_call.stderr)
	var bad_call = _result("EditorConsoleMigrationFixture call add -- nope", ctx)
	check(bad_call.exit_code != 0 and "type mismatch" in bad_call.stderr, "call reports unconvertible args with a failing status")
	var callback = load("res://addons/editor_console/src/class/base/callable_command.gd").new(func(active):
		active.append_output("plugin:" + " ".join(active.unconsumed_tokens))
		return 0)
	ctx.scopes["plugin_callback"] = {"script": callback}
	check(_result("plugin_callback one two", ctx).stdout.strip_edges() == "plugin:one two", "callable scope adapter")
	check(_result("math 2 + 3", ctx).stdout.strip_edges() == "5", "editor math delegates to GDSh expr")
	var fixture = load("res://tests/editor_console/fixtures/global_fixture.gd")
	fixture.calls = 0
	_result("false && os echo $(EditorConsoleMigrationFixture call greeting -- skip)", ctx)
	Sh.Completion.new("os echo $(EditorConsoleMigrationFixture call greeting -- skip)", ctx).get_completions()
	var highlighter = Sh.Console.Highlighter.new()
	highlighter.set_context(ctx)
	check(fixture.calls == 0, "skipped OS commands and completion never execute substitutions")
	if OS.get_name() != "Windows":
		for row in [
			["os printf '%s' $$(printf shell)", "shell"],
			["os printf '%s' '$$HOME'", "$$HOME"],
			['os printf "%s" "$$(printf shell)"', "shell"],
			["os printf '%s' $unknown", ""],
			["echo input | os cat", "input"],
			["os printf 'a\\nb\\n' | count", "2"],
			["os exit 7 || echo recovered", "recovered"],
			["f(){os printf function}; f", "function"],
			["(os printf subshell)", "subshell"],
			["echo $(os printf nested)", "nested"],
			["alias @native = os printf alias; @native", "alias"],
			["os sh -c 'echo error >&2' 2>discard", ""],
		]:
			var result = _result(row[0], ctx)
			check(result.stdout.strip_edges() == row[1] and result.exit_code == 0, "OS behavior: " + row[0] + " got " + result.stdout + result.stderr)
		ctx.variables["$HOME"] = "gdsh-home"
		check(Sh.Completion.new("os echo $$HO", ctx).get_completions().is_empty(), "shell passthrough completion excludes GDSh variables")
		check(Sh.Completion.new("os echo $HO", ctx).get_completions().has("$HOME"), "raw command completion offers GDSh variables")
		check(_result("os printf '%s' $HOME", ctx).stdout.strip_edges() == "gdsh-home", "GDSh variable wins single dollar")
		check(_result("os printf '%s' $$HOME", ctx).stdout.strip_edges() == OS.get_environment("HOME"), "double dollar bypasses GDSh collision")
		ctx.variables["$danger"] = "a; printf wrong"
		check(_result("os printf '%s' $danger", ctx).stdout.strip_edges() == "a; printf wrong", "variable value cannot become shell code")
		var cwd = ctx.cwd
		var target = ProjectSettings.globalize_path("res://tests/editor_console")
		check(_result("os cd " + Adapter.shell_quote(target), ctx).exit_code == 0 and ctx.cwd == target, "OS cd persists into parent context")
		ctx.cwd = cwd
		var error_result = _result("os sh -c 'printf out; printf err >&2; exit 6'", ctx)
		check(error_result.stdout.strip_edges() == "out" and error_result.stderr.strip_edges() == "err" and error_result.exit_code == 6, "OS streams and status stay separate")
	var bridge = load("res://addons/editor_console/src/bridge/console_bridge.gd")
	var scopes = ctx.scopes_hidden.duplicate()
	scopes.merge(ctx.scopes, true)
	var listing = bridge._command_list(scopes)
	for name in ["\nbuiltins echo:", "\nutils count:", "\nmisc editor_console os:", "\necho:", "\nplugin_callback:"]:
		check(name in "\n" + listing, "MCP command listing includes " + name.strip_edges())
	check(not "\nhidden" in "\n" + listing, "MCP command listing does not repeat hidden commands")
	var first = Sh.Context.new_ctx("request", ctx, true)
	first.append_output("bootstrap output")
	var response = bridge._capture("request_value = one; echo first", first)
	check(response.keys() == ["stdout", "stderr", "exit_code"] and response.stdout.strip_edges() == "first", "bridge response shape excludes bootstrap output")
	var second = Sh.Context.new_ctx("request", ctx, true)
	var next = bridge._capture("echo $request_value", second)
	check(next.stdout.strip_edges().is_empty(), "fresh bridge requests isolate session variables")
	_test_prompt(ctx)

## [host, prompt, transcript] wired like a real editor console.
func _make_prompt(ctx:Sh.Context) -> Array:
	# Exercise the real editor submission handler without bootstrapping user .gdrc/settings.
	var host = load("res://addons/editor_console/src/container/console_container.gd").new()
	var prompt = load("res://addons/editor_console/src/container/editor_prompt.gd").new(ctx)
	host.console = prompt
	host.console_ctx = ctx
	host.line_edit = prompt.input
	ctx.host_data["console"] = weakref(host)
	ctx.host_data["clear_callback"] = host._clear_callback # As console_container.new_ctx installs it.
	# The body, not the serialized handler: `test` already runs inside the editor's serial runner.
	prompt.execution_handler = host._run_submission
	prompt.input.completion_factory = host._make_completion
	prompt.echo_values = true
	prompt.host = weakref(host)
	_tree().root.add_child(prompt)
	var transcript = prompt.create_output()
	host.rich_text_label = transcript
	return [host, prompt, transcript]

func _free_prompt(ctx:Sh.Context, host, prompt) -> void:
	prompt.queue_free()
	host.queue_free()
	ctx.host_data.erase("console")
	ctx.host_data.erase("clear_callback")
	ctx.host_data.erase("new_ctx_callback")

func _test_prompt(ctx:Sh.Context):
	var made = _make_prompt(ctx)
	var host = made[0]
	var prompt = made[1]
	var transcript:RichTextLabel = made[2]
	var submitted:Array = []
	var finished:Array = []
	prompt.command_submitted.connect(func(text): submitted.append(text))
	prompt.command_finished.connect(func(text, _result): finished.append(text))
	prompt.execute("value = persisted")
	check(prompt.execute("echo $value").stdout.strip_edges() == "persisted", "interactive variables persist")
	check("echo [persisted]$value" in transcript.get_parsed_text(), "transcript echo previews variable values")
	check(prompt.format_command("echo clean").begins_with("[color="), "editor echo uses input colors")
	check(prompt.execute("echo clean").stdout.strip_edges() == "clean", "submission output is isolated")
	prompt.execute("exit 9")
	check(prompt.execute("echo alive").stdout.strip_edges() == "alive", "exit does not terminate console")
	prompt.execute("os")
	check(host.os_mode and prompt.input.syntax_highlighter == null, "OS toggle switches input mode")
	check(transcript.get_parsed_text().contains("$ Entered OS mode.") and not transcript.get_parsed_text().contains("$ os\n"), "OS toggle prints with the prompt instead of echoing")
	if OS.get_name() != "Windows":
		check(prompt.execute("printf os-mode").stdout.strip_edges() == "os-mode", "persistent OS submission")
		check(prompt.execute("os printf prefixed").stdout.strip_edges() == "prefixed", "OS mode accepts an os prefix")
		check(prompt.command_history.back() == "printf prefixed", "OS mode history drops the os prefix")
	prompt.execute("os")
	check(not host.os_mode, "OS toggle returns to GDSh")
	check(submitted == finished, "one submitted and finished signal per command")
	prompt.execute("clear --history")
	check(prompt.command_history.is_empty() and transcript.text.is_empty(), "clear targets correct transcript/history")
	prompt.execute("echo [color=red]colored[/color]")
	check("colored" in transcript.get_parsed_text(), "editor transcript renders colored output")
	# Stub factory: the real one bootstraps user .gdrc/settings.
	prompt.context_factory = func(): return Sh.Context.new_ctx("fresh", ctx, true)
	prompt.context.cwd = "res://addons/"
	check(prompt.execute("new_ctx && echo nope").stdout.is_empty() and prompt.context != ctx, "new_ctx resets the session")
	check(prompt.context.cwd == ctx.cwd, "new_ctx restores the factory cwd")
	prompt.execute("os")
	var before_os = prompt.context
	check(prompt.execute("new_ctx").exit_code == 0 and prompt.context != before_os, "new_ctx routes to GDSh in OS mode")
	prompt.execute("os")
	_free_prompt(ctx, host, prompt)


func _test_prompt_completion(ctx:Sh.Context):
	var made = _make_prompt(ctx)
	await _test_path_completion(made[0], made[1])
	await _tree().process_frame
	_free_prompt(ctx, made[0], made[1])


func _test_path_completion(host, prompt):
	var input = prompt.input
	var saved_cwd = prompt.context.cwd
	prompt.context.cwd = "res://"
	var absolute = ProjectSettings.globalize_path("res://")
	for prefix in ["./", "./ad", absolute, absolute + "ad"]:
		var base = prefix.left(prefix.rfind("/") + 1)
		await _accept_path_choice(input, "realpath " + prefix, "addons", "realpath " + base + "addons/")
	await _accept_path_choice(input, "realpath ./addons/", "editor_console", "realpath ./addons/editor_console/")
	prompt.execute("os")
	check(host.os_mode, "path completion enters OS mode")
	await _accept_path_choice(input, "cd ./ad", "addons", "cd ./addons/")
	prompt.execute("os")
	prompt.context.cwd = saved_cwd


func _accept_path_choice(input, prefix:String, choice:String, expected:String):
	input.text = prefix
	input.set_caret_column(prefix.length())
	await input.request_completion(true)
	check(input._popup != null and input._popup.visible, "editor path popup: " + prefix)
	if input._popup == null or not input._popup.visible:
		return
	var index = input._popup._choices.find(choice)
	check(index >= 0, "editor path choice: " + prefix)
	if index < 0:
		return
	input._popup._items.select(index)
	input._popup.accept_selected()
	input._timer.stop()
	check(input.text == expected, "editor path insertion: " + input.text)
	check(input.get_caret_column() == expected.length(), "editor path caret")
