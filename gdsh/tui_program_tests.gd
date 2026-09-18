extends RefCounted
const Sh = preload("res://addons/addon_lib/gdsh/_ns/gd_sh.gd")

class Source extends RefCounted:
	signal changed(value)

class Program extends Sh.TUICommand:
	var received:Array = []
	var frames:Array = []
	var views:=0
	var finishes:=0
	var stop_on_init:=false
	var source = Source.new()
	var value:String
	static func get_command_name() -> String: return "program"
	static func get_self_command_data() -> Dictionary: return _command_data({})
	func update(message:TUIMsg) -> void:
		received.append([message.type, message.payload])
		frames.append(Engine.get_process_frames())
		if message.type == TUIMsg.Type.INIT:
			source.changed.connect(_changed)
			if stop_on_init: quit()
		if message.type == TUIMsg.Type.USER:
			value = str(message.payload)
			if value == "outer": post_message(TUIMsg.new(TUIMsg.Type.USER, "inner"))
	func _changed(data) -> void:
		post_message(TUIMsg.new(TUIMsg.Type.SIGNAL, data))
	func view() -> String:
		views += 1
		return value
	func finish() -> void:
		finishes += 1
		if source.changed.is_connected(_changed): source.changed.disconnect(_changed)
		post_message(TUIMsg.new(TUIMsg.Type.USER, "after finish"))


class MultiMode extends Program:
	static func get_self_command_data() -> Dictionary: return _command_data({&"positional_count": "min:0,max:1"})
	func _execute(ctx:Sh.Context):
		if "plain" in positional_args:
			ctx.append_output("ordinary mode")
			return ExitCode.OK
		var status = await run()
		ctx.append_output("after TUI")
		return status


func _frames() -> void:
	for frame in 5: await (Engine.get_main_loop() as SceneTree).process_frame


func run(suite) -> void:
	var console = Sh.Console.new()
	console.create_output()
	(Engine.get_main_loop() as SceneTree).root.add_child(console)
	console.size = Vector2(500, 250)
	var program = Program.new()
	console.context.scopes["program"] = {"script": program}
	console.execute("program")
	program.post_message(Sh.TUIMsg.new(Sh.TUIMsg.Type.USER, "queued before init"))
	await _frames()
	suite.check(program.received[0][0] == Sh.TUIMsg.Type.INIT and program.received[1][1] == "queued before init", "TUI initializes before queued input")
	suite.check(program.viewport_size.x > 0 and program.viewport_size.y > 0, "TUI initializes with usable dimensions")
	var count = program.views
	program.post_message(Sh.TUIMsg.new(Sh.TUIMsg.Type.USER, "a"))
	program.post_message(Sh.TUIMsg.new(Sh.TUIMsg.Type.USER, "b"))
	program.source.changed.emit({"count": 3})
	await _frames()
	suite.equal(program.views, count + 1, "TUI batches messages into one render")
	suite.equal(program.received[-3], [Sh.TUIMsg.Type.USER, "a"], "TUI preserves first queued message")
	suite.equal(program.received[-2], [Sh.TUIMsg.Type.USER, "b"], "TUI preserves second queued message")
	suite.equal(program.received[-1], [Sh.TUIMsg.Type.SIGNAL, {"count": 3}], "signal callbacks post arbitrary Variant payloads")
	count = program.views
	await _frames()
	suite.equal(program.views, count, "TUI does not render while idle")
	program.post_message(Sh.TUIMsg.new(Sh.TUIMsg.Type.USER, "outer"))
	await _frames()
	suite.check(program.received[-1][1] == "inner" and program.frames[-1] > program.frames[-2], "messages posted during update wait for the next frame")
	var old_size = program.viewport_size
	console.size.y = 150
	await _frames()
	suite.check(program.viewport_size.y < old_size.y and program.received[-1] == [Sh.TUIMsg.Type.RESIZE, program.viewport_size], "TUI resize delivers updated row count")
	old_size = program.viewport_size
	console.active_tui.display.add_theme_font_size_override("normal_font_size", 24)
	await _frames()
	suite.check(program.viewport_size.x < old_size.x and program.received[-1][0] == Sh.TUIMsg.Type.RESIZE, "TUI font changes update cell dimensions")
	program.post_message(Sh.TUIMsg.new(Sh.TUIMsg.Type.USER, "discard"))
	program.quit(7)
	program.quit()
	count = program.received.size()
	program.post_message(Sh.TUIMsg.new(Sh.TUIMsg.Type.USER, "late"))
	program.source.changed.emit("late signal")
	await _frames()
	suite.check(program.finishes == 1 and program.received.size() == count, "TUI cleans up once, discards queued input and ignores late callbacks")
	suite.check(not program.source.changed.has_connections(), "TUI finish disconnects application signal subscriptions")
	suite.equal(console.last_result.exit_code, 7, "TUI returns its explicit exit code")
	program.stop_on_init = true
	console.execute("program")
	await _frames()
	suite.check(not console.is_busy and console.last_result.exit_code == 0 and program.finishes == 2, "quitting synchronously in INIT releases the awaited command")
	program.stop_on_init = false
	console.execute("program")
	await _frames()
	console.context.scopes["program"].clear()
	console.context.scopes.erase("program")
	console.queue_free()
	await _frames()
	suite.equal(program.finishes, 3, "host teardown invokes TUI finish exactly once")
	console = Sh.Console.new()
	console.create_output()
	(Engine.get_main_loop() as SceneTree).root.add_child(console)
	console.size = Vector2(500, 250)
	var modes = MultiMode.new()
	console.context.scopes["program"] = {"script": modes}
	var plain = await console.execute("program plain")
	suite.check(plain.stdout == "ordinary mode\n" and modes.received.is_empty() and console.active_tui == null, "overridden execution can return without acquiring a TUI")
	console.execute("program")
	await _frames()
	var session = console.active_tui
	var duplicate = await modes.run()
	suite.check(duplicate == Sh.Context.ExitCode.FAIL and console.active_tui == session and modes.finishes == 0, "overlapping run is rejected without closing the active session")
	modes.quit(7)
	await _frames()
	suite.check(console.last_result.exit_code == 7 and console.last_result.stdout == "after TUI\n" and modes.finishes == 1, "run returns its status to the overriding execution method")
	console.execute("program")
	await _frames()
	var cancel = InputEventKey.new()
	cancel.keycode = KEY_C
	cancel.ctrl_pressed = true
	cancel.pressed = true
	modes._on_input(cancel)
	await _frames()
	suite.check(console.last_result.exit_code == Sh.Context.ExitCode.FAIL and modes.finishes == 2, "a subsequent run has fresh lifecycle state and supports cancellation")
	console.context.scopes["program"].clear()
	console.context.scopes.erase("program")
	console.queue_free()
	await _frames()
