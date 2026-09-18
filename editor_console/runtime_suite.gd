extends RefCounted
## Editor Console runtime checks, driven by runtime_test.gd (headless and editor console `test`).
const Sh = preload("res://addons/addon_lib/gdsh/_ns/gd_sh.gd")
const TUIList = preload("res://tests/gdsh/fixtures/tui_list.gd")
const Adapter = preload("res://addons/editor_console/src/utils/os_adapter.gd")
var checks:int = 0
var failures:int = 0
var report:Array[String] = []
var _ctx:Sh.Context

# Exercise the real serial runner without initializing editor-only settings/plugins.
class SerialRunnerProbe extends EditorConsoleSingleton:
	func _init(_plugin:EditorPlugin=null) -> void:
		pass
	func _ready() -> void:
		pass

class DockedPromptProbe extends "res://addons/editor_console/src/container/editor_prompt.gd":
	var log_control:Control
	func _get_editor_log() -> Control:
		return log_control if is_instance_valid(log_control) else null

class CurrentScriptProbe extends "res://addons/editor_console/src/default_commands/editor/script/script.gd":
	var selected:Script
	func _current_script() -> Script:
		return selected

class EditorRouterProbe extends "res://addons/editor_console/src/default_commands/editor/editor.gd":
	var selected:Script
	var exact_override:bool = false
	func _get_commands() -> Dictionary:
		var commands = preload("res://addons/editor_console/src/default_commands/editor/editor.gd").new().get_commands()
		commands["script"][&"get_command"] = func():
			var command = CurrentScriptProbe.new()
			command.selected = selected
			return command
		if exact_override:
			commands["script.Inner"] = {&"get_command": func(): return preload("res://addons/addon_lib/gdsh/builtins/echo/echo.gd").new()}
		return commands

class TempConfig extends EditorConsoleSingleton.UtilsLocal.Config:
	func write():
		_write_config(data, file_path, false)

class RegistryProbe extends "res://addons/editor_console/src/default_commands/config/global/registry/registry.gd":
	var project_config
	var user_config
	func _target_config():
		return user_config if global_flag else project_config

class GlobalConfigProbe extends "res://addons/editor_console/src/default_commands/config/global/global.gd":
	var project_config
	var user_config
	func _get_commands() -> Dictionary:
		return {"registry": {&"get_command": func():
			var command = RegistryProbe.new()
			command.project_config = project_config
			command.user_config = user_config
			return command}}

class ConfigRouterProbe extends "res://addons/editor_console/src/default_commands/config/config.gd":
	var global_config
	func _get_commands() -> Dictionary:
		return {"global": {&"get_command": func(): return global_config}}

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
	check(not ctx.scopes.has("plugin") and Sh.Completion.new("editor plug", ctx).get_completions().has("plugin"), "plugin TUI lives under editor plugin")
	check(Sh.Completion.new("editor plugin ", ctx).get_completions().has("enable"), "existing editor plugin subcommands remain available")
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
	_test_script_adapter(ctx)
	_test_global_registry(ctx)
	_ctx = ctx

## Prompt path completion waits on the completion popup; headless only.
func run_frames():
	await _test_prompt_completion(_ctx)
	await _test_tui_serial_lifecycle()
	await _test_docked_tui()
	await preload("res://tests/editor_console/plugin_tui_tests.gd").new().run(self)


func _test_tui_serial_lifecycle() -> void:
	var runner = SerialRunnerProbe.new()
	var prompt = load("res://addons/editor_console/src/container/editor_prompt.gd").new()
	var editor_binding = weakref(runner)
	prompt.context.scopes["test_tui_list"] = {"script": TUIList}
	prompt.context.host_data["console"] = editor_binding
	prompt.create_output()
	_tree().root.add_child(prompt)
	prompt.size = Vector2(500, 300)
	prompt.execution_handler = func(text, ctx):
		await runner._run_serialized(func(): return await Sh.Execute.execute_command_multiline(text, ctx))
	prompt.execute("test_tui_list")
	for frame in 3: await _tree().process_frame
	check(prompt.active_tui != null and runner._serial_running, "editor TUI owns the serialized command slot")
	check(prompt.context.host_data.console == editor_binding, "TUI service preserves the editor console binding")
	var results:Array = []
	_queued_after_tui(runner, results)
	check(results.is_empty(), "editor work queues behind the TUI")
	prompt.queue_free()
	for frame in 5: await _tree().process_frame
	check(results == ["after"] and not runner._serial_running, "closing the TUI host releases the editor serial queue")
	runner.free()


func _queued_after_tui(runner, results:Array) -> void:
	await runner._run_serialized(func(): results.append("after"))

func _tui_frames() -> void:
	for frame in 5: await _tree().process_frame

func _test_docked_tui() -> void:
	# EditorLog is a MarginContainer in 4.6; keep the prompt inside the body we hide.
	var log_control = MarginContainer.new()
	log_control.custom_minimum_size = Vector2(0, 180)
	_tree().root.add_child(log_control)
	log_control.size = Vector2(600, 320)
	var body = VBoxContainer.new()
	log_control.add_child(body)
	var transcript = RichTextLabel.new()
	transcript.text = "existing log"
	transcript.custom_minimum_size.y = 200
	transcript.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(transcript)
	var initially_hidden = Control.new()
	initially_hidden.hide()
	log_control.add_child(initially_hidden)
	var prompt = DockedPromptProbe.new()
	prompt.context.scopes["test_tui_list"] = {"script": TUIList}
	prompt.log_control = log_control
	body.add_child(prompt)
	var runner = SerialRunnerProbe.new()
	prompt.execution_handler = func(text, ctx):
		await runner._run_serialized(func(): return await Sh.Execute.execute_command_multiline(text, ctx))
	await _tui_frames()
	var minimum_before = log_control.get_combined_minimum_size()
	var captured = await prompt.execute("echo $(test_tui_list)")
	check(captured.stderr.contains("stdout is captured") and body.visible, "docked TUI rejects captured output before changing visibility")
	prompt.execute("test_tui_list")
	await _tui_frames()
	var session = prompt.active_tui
	check(session != null and session.get_parent() == log_control and not body.visible and not initially_hidden.visible,
		"docked TUI takes over the whole editor log and hides the prompt ancestor")
	if session == null:
		log_control.queue_free()
		runner.free()
		return
	check(session.display.has_focus() and session.display.size.y > 0 and prompt.is_busy, "docked TUI receives focus and layout while its prompt is hidden")
	check(log_control.get_combined_minimum_size().y >= minimum_before.y, "docked TUI retains the content minimum so the bottom panel cannot collapse to its footer")
	transcript.append_text("\nbackground log")
	session.close(0)
	await _tui_frames()
	check(body.visible and not initially_hidden.visible and prompt.input.has_focus() and not prompt.is_busy,
		"docked TUI restores original visibility and prompt focus")
	check(transcript.get_parsed_text() == "existing log\nbackground log" and log_control.custom_minimum_size == Vector2(0, 180),
		"docked TUI preserves transcript updates and existing layout settings")
	prompt.execute("test_tui_list")
	await _tui_frames()
	prompt.active_tui.queue_free()
	await _tui_frames()
	check(body.visible and not prompt.is_busy and prompt.active_tui == null, "external session removal restores the dock and resolves execution")
	prompt.execute("test_tui_list")
	await _tui_frames()
	var results:Array = []
	_queued_after_tui(runner, results)
	prompt.queue_free()
	await _tui_frames()
	check(body.visible and not initially_hidden.visible and results == ["after"] and not runner._serial_running,
		"prompt teardown restores its external host and releases queued editor work")
	log_control.queue_free()
	runner.free()
	await _tui_frames()
	var missing = DockedPromptProbe.new()
	missing.context.scopes["test_tui_list"] = {"script": TUIList}
	_tree().root.add_child(missing)
	var result = await missing.execute("test_tui_list")
	check(result.stderr.contains("interactive console view") and not missing.is_busy, "missing editor log rejects TUI acquisition cleanly")
	missing.queue_free()
	await _tui_frames()

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
	Sh.Utils.clear_global_class_cache()
	ctx.scope_resolver = EditorConsoleSingleton._resolve_editor_scope
	# `global` is gone: GDSh core resolves a bare global class name to the core `script` command.
	for text in ["EditorConsoleMigrationFixture call greeting -- world", "script EditorConsoleMigrationFixture call greeting -- world", "EditorConsoleMigrationFixture.Inner call answer"]:
		var result = _result(text, ctx)
		check(result.exit_code == 0 and ("hello world" in result.stdout or "42" in result.stdout), "script call: " + text + ": " + result.stderr)
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


func _test_script_adapter(parent:Sh.Context):
	var ctx = Sh.Context.new_ctx("editor script", parent)
	var router = EditorRouterProbe.new()
	router.selected = load("res://tests/editor_console/fixtures/global_fixture.gd")
	ctx.scopes["editor"] = {"script": router}
	for head in ["editor script", "editor script.Inner"]:
		var method = "greeting -- world" if head == "editor script" else "answer"
		var result = _result(head + " call " + method, ctx)
		check(result.exit_code == 0 and ("hello world" in result.stdout or "42" in result.stdout), "editor script routes " + head + ": " + result.stderr)
		check(Sh.Completion.new(head + " call ", ctx).get_completions().has(method.get_slice(" ", 0)), "editor script method completion " + head)
	var choices = Sh.Completion.new("editor script.In", ctx).get_completions()
	check(choices.has("Inner") and choices.Inner[Sh.Options.Keys.METADATA][Sh.Options.Keys.INSERT] == "script.Inner", "editor member completion preserves selector")
	var nested = _result("editor script.Inner.Nested call answer", ctx)
	check(nested.exit_code == 0 and nested.stdout.strip_edges().ends_with("84"), "editor nested inner-class routing")
	choices = Sh.Completion.new("editor script.Inner.N", ctx).get_completions()
	check(choices.has("Nested") and choices.Nested[Sh.Options.Keys.METADATA][Sh.Options.Keys.INSERT] == "script.Inner.Nested", "editor nested completion preserves chain")
	check(_result("editor script.Missing call answer", ctx).exit_code != 0, "editor missing member fails")
	check(_result("editor script.Inner get_path", ctx).stdout.contains("inner_fixture.gd"), "editor preloaded member get_path")
	check(not Sh.Completion.new("editor script ", ctx).get_completions().has("list_global"), "editor adapter exposes target commands only")
	check(_result("editor script --class=GDSh call greeting", ctx).exit_code != 0, "editor adapter rejects replacement targets")
	var result = _result("editor script --text", ctx)
	check(result.exit_code == 0 and result.stdout.contains("class_name EditorConsoleMigrationFixture"), "editor --text reads selected resource")
	router.exact_override = true
	check(_result("editor script.Inner exact", ctx).stdout.strip_edges() == "exact", "exact editor children beat dotted fallback")
	router.exact_override = false
	router.selected = null
	result = _result("editor script call greeting", ctx)
	check(result.exit_code != 0 and result.stderr.contains("No script open"), "missing editor script error")
	check(_result("editor script --help", ctx).exit_code == 0, "editor script help without a current script")
	check(_result("script call greeting", ctx).exit_code != 0, "root script has no editor fallback")
	router._ctx_obj = null # Break the test router/context cycle.


func _test_global_registry(parent:Sh.Context):
	var Config = EditorConsoleSingleton.UtilsLocal.Config
	var project = TempConfig.new()
	project.file_path = "user://registry_project_test.yml"
	project.data = {}
	var user = TempConfig.new()
	user.file_path = "user://registry_user_test.yml"
	user.data = {}
	var global = GlobalConfigProbe.new()
	global.project_config = project
	global.user_config = user
	var router = ConfigRouterProbe.new()
	router.global_config = global
	var ctx = Sh.Context.new_ctx("registry", parent)
	ctx.scopes["config"] = {"script": router}
	var name = "EditorConsoleMigrationFixture"
	check(_result("config global registry --add " + name + " StaleClass", ctx).exit_code == 0, "registry adds several project names")
	check(Config._get_config_data(project.file_path).get(Config.GLOBAL_CLASSES, []) == [name, "StaleClass"], "registry persists legacy config key")
	check(user.data.is_empty(), "default registry edits do not affect user config")
	check(_result("config global registry --add " + name, ctx).exit_code != 0, "registry duplicate error")
	check(_result("config global registry --rm Missing", ctx).exit_code != 0, "registry missing removal error")
	check(_result("config global registry --add --rm " + name, ctx).exit_code != 0, "registry conflicting flags error")
	check(_result("config global registry " + name, ctx).stdout.contains("true"), "registry status query")
	check(_result("config global registry --global --add GDSh", ctx).exit_code == 0, "registry user config selection")
	check(Config._get_config_data(user.file_path).get(Config.GLOBAL_CLASSES, []) == ["GDSh"], "registry persists user selection")
	var merged = project.data.duplicate(true)
	Config._recursive_merge(merged, user.data)
	ctx.host_data["script_targets"] = func(): return PackedStringArray(merged.get(Config.GLOBAL_CLASSES, []))
	var choices = Sh.Completion.new("script ", ctx).get_completions()
	check(choices.has(name) and choices.has("GDSh") and not choices.has("StaleClass"), "merged registry suggestions filter stale entries")
	check(Sh.Completion.new("config global registry --rm ", ctx).get_completions().has("StaleClass"), "stale registrations can be removed through completion")
	check(not Sh.Completion.new("config global registry --add ", ctx).get_completions().has(name), "add completion omits registered names")
	check(_result("config global registry --rm " + name + " StaleClass", ctx).exit_code == 0, "registry removes several project names")
	check(Config._get_config_data(project.file_path).get(Config.GLOBAL_CLASSES, []) == [], "registry removal persists")
	ctx.host_data["script_targets"] = func(): return PackedStringArray()
	check(_result(name + " call greeting -- unregistered", ctx).exit_code == 0, "unregistered classes still execute")
	check(not parent.has_scope("global"), "no root global command restored")
	check(Sh.Completion.new("config global ", parent).get_completions().has("registry"), "real config namespace discovers registry")
	router._ctx_obj = null
	global._ctx_obj = null
	DirAccess.remove_absolute(project.file_path)
	DirAccess.remove_absolute(user.file_path)
