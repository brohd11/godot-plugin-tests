extends RefCounted
## Frame-based integration checks: real focused input, display ownership and teardown.
const Sh = preload("res://addons/addon_lib/gdsh/_ns/gd_sh.gd")
const TUIList = preload("res://tests/gdsh/fixtures/tui_list.gd")
var suite

class InputProbe extends Node:
	var events:Array = []
	func _unhandled_input(event:InputEvent) -> void:
		events.append(event)


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames() -> void:
	for frame in 3:
		await _tree().process_frame


func _key(code:int, echo:=false, ctrl:=false) -> void:
	var event = InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.echo = echo
	event.ctrl_pressed = ctrl
	Input.parse_input_event(event)
	await _frames()
	event = event.duplicate()
	event.pressed = false
	event.echo = false
	Input.parse_input_event(event)
	await _frames()


func _selected_visible(display:RichTextLabel, index:int) -> bool:
	var bar = display.get_v_scroll_bar()
	var lines = display.get_parsed_text().split("\n")
	var label = "> Item %03d" % (index + 1)
	var row = Array(lines).find(label)
	if row < 0: return false
	var top = display.get_paragraph_offset(row)
	var available = display.size.y - display.get_theme_stylebox("normal").get_minimum_size().y
	return bar.value == 0 and top + display.get_line_height(row) <= available + 1


func run(owner) -> void:
	suite = owner
	await _test_row_capacity()
	var console = Sh.Console.new()
	console.context.scopes["test_tui_list"] = {"script": TUIList}
	var transcript = console.create_output()
	_tree().root.add_child(console)
	console.size = Vector2(500, 260)
	await _frames()
	await console.execute("echo preserved")
	var before = transcript.get_parsed_text()
	var probe = InputProbe.new()
	_tree().root.add_child(probe)
	console.execute("test_tui_list")
	await _frames()
	var session = console.active_tui
	suite.check(session != null and console.is_busy, "TUI opens and keeps its command busy")
	if session == null:
		console.queue_free()
		probe.queue_free()
		return
	var display:RichTextLabel = session.display
	suite.check(display.has_focus() and not transcript.visible and not console._input_panel.visible, "TUI replaces the transcript and prompt and receives focus")
	suite.check(display.get_parsed_text().contains("> Item 001"), "TUI initially selects the first row")
	suite.check(display.text.contains("[bgcolor="), "TUI selection uses background color")
	suite.check(not display.scroll_active and not display.get_v_scroll_bar().visible and display.get_v_scroll_bar().value == 0, "TUI has no native scrolling or scrollbar")
	suite.check(not display.get_parsed_text().contains("Item 100"), "TUI renders only its viewport slice")
	suite.check(display.get_theme_font("normal_font") == console.SourceFont, "TUI inherits the console source font")
	await _key(KEY_UP)
	suite.check(display.get_parsed_text().contains("> Item 001"), "TUI selection clamps at the start")
	await _key(KEY_DOWN)
	await _key(KEY_DOWN, true)
	suite.check(display.get_parsed_text().contains("> Item 003"), "TUI arrows and held-key repeats move selection")
	await _key(KEY_PAGEDOWN)
	suite.check(not display.get_parsed_text().contains("> Item 003") and not display.get_parsed_text().contains("Item 001"), "TUI page navigation advances its drawn viewport")
	await _key(KEY_END)
	suite.check(display.get_parsed_text().contains("> Item 100") and _selected_visible(display, 99), "TUI End reveals the last row")
	await _key(KEY_DOWN, true)
	suite.check(display.get_parsed_text().contains("> Item 100"), "TUI selection clamps at the end")
	console.size.y = 170
	await _frames()
	suite.check(_selected_visible(display, 99), "TUI resize keeps selection visible")
	await _key(KEY_HOME)
	suite.check(_selected_visible(display, 0), "TUI Home reveals the first row")
	var scroll = InputEventMouseButton.new()
	scroll.position = display.global_position + Vector2(8, 8)
	scroll.button_index = MOUSE_BUTTON_WHEEL_DOWN
	scroll.pressed = true
	Input.parse_input_event(scroll)
	await _frames()
	suite.check(display.get_v_scroll_bar().value == 0 and not display.get_parsed_text().contains("Item 001"), "TUI wheel changes its drawn slice without native scrolling")
	var previous = display.get_parsed_text().get_slice("\n", 0)
	var pan = InputEventPanGesture.new()
	pan.position = scroll.position
	pan.delta = Vector2(0, 2)
	Input.parse_input_event(pan)
	await _frames()
	suite.check(display.get_parsed_text().get_slice("\n", 0) != previous and display.get_v_scroll_bar().value == 0, "TUI trackpad changes the drawn viewport")
	await _key(KEY_UP)
	suite.check(_selected_visible(display, 0), "TUI scrolling preserves selection and navigation reveals it again")
	await _key(KEY_TAB)
	suite.check(display.has_focus(), "TUI Tab does not escape into shell focus navigation")
	suite.check(probe.events.is_empty(), "TUI consumes keys, repeats, releases and scrolling")
	var closes:Array = []
	session.closed.connect(func(value): closes.append(value))
	await _key(KEY_ENTER)
	suite.check(not console.is_busy and console.active_tui == null, "TUI Enter finishes its submission")
	suite.equal(closes, [Sh.Context.ExitCode.OK], "TUI base closes exactly once with its exit code")
	suite.equal(console.last_result.stdout, "Item 001\n", "TUI stdout contains only the chosen label")
	suite.check(transcript.get_parsed_text().begins_with(before) and transcript.get_parsed_text().count("Item 001") == 1, "TUI preserves transcript and prints the result once")
	suite.check(not transcript.get_parsed_text().contains("Item 100"), "TUI redraws never enter the transcript")
	suite.check(console._input_panel.visible and transcript.visible and console.input.has_focus() and console.input.editable, "TUI restores prompt visibility, focus and editing")
	probe.queue_free()

	for code in [KEY_ESCAPE, KEY_C]:
		console.execute("test_tui_list")
		await _frames()
		await _key(code, false, code == KEY_C)
		suite.check(not console.is_busy and console.last_result.stdout.is_empty() and console.last_result.exit_code == Sh.Context.ExitCode.FAIL, "TUI cancellation returns FAIL with no output")
	# Submission identity survives subshell contexts, which have no parent_ctx.
	console.execute("(test_tui_list)")
	await _frames()
	suite.check(console.active_tui != null, "TUI can open from a submitted subshell")
	await _key(KEY_ESCAPE)

	# Entry failures must not leave a command waiting for interaction.
	for command in ["echo $(test_tui_list)", "test_tui_list | echo after", "test_tui_list > user://gdsh_tui_redirect.txt"]:
		await console.execute(command)
		suite.check(console.active_tui == null and not console.is_busy and console.last_result.stderr.contains("stdout is captured"), "TUI rejects captured stdout: " + command)
	DirAccess.remove_absolute("user://gdsh_tui_redirect.txt")
	var unavailable = Sh.Console.new()
	unavailable.context.scopes["test_tui_list"] = {"script": TUIList}
	_tree().root.add_child(unavailable)
	var result = await unavailable.execute("test_tui_list")
	suite.check(result.exit_code != 0 and result.stderr.contains("interactive console view"), "TUI rejects a prompt without an output area")
	unavailable.queue_free()
	var unhosted = Sh.Context.new()
	unhosted.scopes["test_tui_list"] = {"script": TUIList}
	result = await Sh.Execute.execute_command_multiline("test_tui_list", unhosted)
	suite.check(result.exit_code != 0 and result.stderr.contains("interactive console view"), "TUI rejects non-UI execution")

	# Custom commands can leave a session open; the submission owns final cleanup.
	var leaked:Array = []
	console.execution_handler = func(_text, ctx):
		var view = ctx.host_data.tui_begin.call(ctx)
		leaked.append(view)
		var duplicate = ctx.host_data.tui_begin.call(ctx)
		suite.check(duplicate == null and ctx.stderr.contains("already active"), "TUI refuses a second owner")
		ctx.append_output("ordinary output")
	await console.execute("custom")
	suite.check(console.active_tui == null and leaked[0].is_closed, "submission completion closes a leftover TUI")
	suite.check(transcript.get_parsed_text().count("ordinary output") == 1, "ordinary output during TUI ownership still reaches the transcript once")
	leaked[0].close("late")
	console.execution_handler = Callable()
	await _frames()

	# Preserve deliberately hidden controls instead of unconditionally showing them.
	console._input_panel.hide()
	transcript.hide()
	console.execute("test_tui_list")
	await _frames()
	console.active_tui.close()
	suite.check(not transcript.visible and not console._input_panel.visible, "TUI restores previous hidden state")
	console._input_panel.show()
	transcript.show()
	await _frames()
	console.execute("test_tui_list")
	await _frames()
	console.size.y = 1
	await _frames()
	suite.check(console.active_tui.get_viewport_size_in_cells().y == 0 and console.active_tui.display.text.is_empty(), "TUI renders an empty viewport when only the footer fits")
	await _key(KEY_ESCAPE)
	suite.check(not console.is_busy and console.active_tui == null, "TUI still handles exit input when no rows fit")
	console.size.y = 260
	await _frames()

	# Window deletion must resolve the awaiting command before freeing its controls.
	var results:Array = []
	_finish_after_close(console, results)
	await _frames()
	console.queue_free()
	await _frames()
	suite.check(results.size() == 1 and results[0].exit_code == Sh.Context.ExitCode.FAIL, "console teardown releases the awaiting TUI command")


func _finish_after_close(console, results:Array) -> void:
	results.append(await console.execute("test_tui_list"))


func _test_row_capacity() -> void:
	var session = preload("res://addons/addon_lib/gdsh/src/tui/tui_session.gd").new()
	_tree().root.add_child(session)
	var display = session.display
	for font in [Sh.Console.SourceFont, ThemeDB.fallback_font]:
		for font_size in [16, 28]:
			for spacing in [0, 4]:
				display.add_theme_font_override("normal_font", font)
				display.add_theme_font_size_override("normal_font_size", font_size)
				display.add_theme_constant_override("line_separation", spacing)
				display.add_theme_constant_override("paragraph_separation", spacing)
				var style = StyleBoxEmpty.new()
				style.content_margin_top = spacing + 3
				style.content_margin_bottom = spacing + 7
				display.add_theme_stylebox_override("normal", style)
				for height in [25, 50, 170, 260, 440]:
					session.size = Vector2(500, height)
					await _frames()
					var rows = session.get_viewport_size_in_cells().y
					var lines:PackedStringArray = []
					for row in rows + 1: lines.append("Mg")
					display.text = "\n".join(lines)
					var available = display.size.y - style.get_minimum_size().y
					var first = display.get_paragraph_offset(0)
					var last_bottom = display.get_paragraph_offset(rows - 1) - first + display.get_line_height(rows - 1) if rows > 0 else 0.0
					var next_bottom = display.get_paragraph_offset(rows) - first + display.get_line_height(rows)
					suite.check((rows == 0 or last_bottom <= available) and next_bottom > available,
						"TUI row budget fits exactly: size=%d spacing=%d height=%d rows=%d bottom=%s next=%s available=%s" % [font_size, spacing, height, rows, last_bottom, next_bottom, available])
	session.close()
	await _frames()
