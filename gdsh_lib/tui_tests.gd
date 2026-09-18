extends RefCounted
const Sh = preload("res://addons/addon_lib/gdsh/_ns/gd_sh.gd")
const Flow = preload("res://tests/gdsh_lib/fixtures/tui_flow.gd")
const TUI = preload("res://addons/addon_lib/gdsh_lib/tui/manifest.gd").TUI

class Probe extends TUI.Component:
	var received:Array = []
	var finishes:=0
	var consumes:=false
	func update(message:TUIMsg) -> bool:
		received.append(message)
		return consumes
	func finish() -> void: finishes += 1

class Page extends TUI.Screen:
	var starts:=0
	var pauses:=0
	var returns:Array = []
	var finishes:=0
	var received:Array = []
	var on_message:Callable
	var on_init:Callable
	var draws:=0
	var text:String = "page"
	func init() -> void:
		starts += 1
		if on_init.is_valid(): on_init.call()
	func suspend() -> void: pauses += 1
	func resume(value:Variant) -> void: returns.append(value)
	func finish() -> void:
		finishes += 1
		on_message = Callable()
		on_init = Callable()
	func update(message:TUIMsg) -> bool:
		received.append(message)
		if on_message.is_valid(): on_message.call(message)
		return super(message)
	func view() -> String:
		draws += 1
		return text

class Entry extends TUI.TextEntry:
	func _clipboard_text() -> String: return "é\r\n[x]\t!"

class Command extends TUI.ScreenCommand:
	var page:Page
	var close_on_init:=false
	var invalid_root:=false
	static func get_command_name() -> String: return "screen_test"
	static func get_self_command_data() -> Dictionary: return _command_data({})
	func create_screen() -> Screen:
		page = Page.new()
		if close_on_init: page.on_init = page.pop.bind("immediate")
		if invalid_root: page._dispose()
		return page

static func key(code:int, echo:=false, unicode:=0, shift:=false, ctrl:=false, meta:=false) -> Sh.TUIMsg:
	var event = InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.echo = echo
	event.unicode = unicode
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	event.meta_pressed = meta
	return Sh.TUIMsg.new(Sh.TUIMsg.Type.KEY, event)

func run_sync(suite) -> void:
	suite.check(Sh.Load.load_directory("res://addons/addon_lib/gdsh_lib/tui").is_empty(), "TUI library registers no shell commands")
	_test_router(suite)
	_test_focus(suite)
	_test_list(suite)
	_test_entry(suite)
	_test_confirmation(suite)
	_test_flow(suite)

func _test_router(suite) -> void:
	var router = TUI.Router.new()
	router.set_size(Vector2i(40, 10))
	var root = Page.new()
	var child = Page.new()
	var replacement = Page.new()
	var component = Probe.new()
	root.add_component(component)
	router.push(root)
	suite.check(root.starts == 1 and root.size == Vector2i(40, 10) and component.focused, "router initializes root with dimensions and focus")
	var snapshots:Array = []
	root.on_message = func(_message):
		root.push(child)
		snapshots.append(router.top() == root)
	router.update(key(KEY_ENTER))
	root.on_message = Callable()
	suite.check(snapshots == [true] and router.top() == child and child.received.is_empty(), "navigation commits after update and never forwards the triggering input")
	suite.check(root.pauses == 1 and not component.focused and child.starts == 1, "push suspends and blurs the retained screen")
	var before = root.received.size()
	router.update(Sh.TUIMsg.new(Sh.TUIMsg.Type.USER, "child only"))
	suite.check(root.received.size() == before and child.received.size() == 1, "application messages go only to the top screen")
	router.set_size(Vector2i(20, 3))
	suite.check(root.size == Vector2i(40, 10) and child.size == Vector2i(20, 3), "covered screens defer layout until resumed")
	child.replace(replacement)
	suite.check(child.finishes == 1 and replacement.starts == 1 and root.returns.is_empty(), "replace finishes the current screen without resuming its parent")
	replacement.pop({"answer": 42})
	suite.check(root.returns == [{"answer": 42}] and root.starts == 1 and root.size == Vector2i(20, 3) and component.focused,
		"pop returns a result, resizes and restores the original screen and focus")
	child.push(Page.new())
	suite.check(router.top() == root, "finished screens cannot navigate")
	var results:Array = []
	router.completed.connect(func(value): results.append(value))
	router.update(key(KEY_ESCAPE, true))
	suite.check(router.top() == root, "held Escape cannot unwind multiple screens")
	router.update(key(KEY_ESCAPE))
	router.finish()
	suite.check(results == [null] and root.finishes == 1 and component.finishes == 1, "root Escape completes once and disposes owned components")
	router = TUI.Router.new()
	root = Page.new()
	child = Page.new()
	root.on_init = func(): root.push(child)
	router.push(root)
	root.on_init = Callable()
	suite.check(router.top() == child and root.starts == 1 and child.starts == 1, "navigation from init is drained without reentrant initialization")
	root.pop("late")
	suite.check(router.top() == child, "covered screens cannot pop the active child")
	router.finish()
	router.finish()
	suite.check(root.finishes == 1 and child.finishes == 1 and router.top() == null, "cancellation cleans every retained screen exactly once")

func _test_focus(suite) -> void:
	var screen = TUI.Screen.new()
	var a = Probe.new()
	var b = Probe.new()
	screen.add_component(a)
	screen.add_component(b)
	screen.set_focused(true)
	screen.update(key(KEY_TAB))
	suite.check(not a.focused and b.focused and a.received.is_empty() and b.received.is_empty(), "Tab moves focus without feeding components")
	screen.update(key(KEY_TAB, false, 0, true))
	suite.check(a.focused and not b.focused, "Shift+Tab reverses focus")
	a.consumes = true
	var requests:Array = []
	screen.navigation_requested.connect(func(op, value): requests.append([op, value]))
	screen.update(key(KEY_ESCAPE))
	suite.check(requests.is_empty(), "components can consume Escape before screen navigation")
	screen.remove_component(a)
	suite.check(a.finishes == 1 and b.focused, "removing the focused component cleans it up and selects its neighbor")
	screen._dispose()
	suite.check(a.finishes == 1 and b.finishes == 1, "screen cleanup does not finish removed components twice")

func _test_list(suite) -> void:
	var list = TUI.List.new()
	var items:Array[TUI.List.Item] = []
	for i in 20: items.append(TUI.List.Item.new(str(i), "Row %02d [x]" % i, i))
	list.set_items(items)
	list.set_size(Vector2i(30, 3))
	list.set_focused(true)
	list.update(key(KEY_END))
	suite.check(list.selected_index == 19 and list.first_visible == 17 and list.view().split("\n").size() == 3, "list End reveals the final page within its height")
	list.update(key(KEY_HOME))
	var wheel = InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.factor = 0.1
	for i in 4: list.update(Sh.TUIMsg.new(Sh.TUIMsg.Type.MOUSE, wheel))
	suite.check(list.first_visible == 1 and list.selected_index == 0, "fractional wheel input accumulates without changing selection")
	var pan = InputEventPanGesture.new()
	pan.delta.y = 1
	list.update(Sh.TUIMsg.new(Sh.TUIMsg.Type.MOUSE, pan))
	suite.check(list.first_visible == 4, "trackpad input scrolls the list slice")
	list.update(key(KEY_DOWN))
	suite.check(list.selected_index == 1 and list.first_visible == 1, "keyboard navigation reveals the retained selection")
	items.reverse()
	list.set_items(items)
	suite.check(list.get_selected().id == "1" and list.selected_index == 18, "list refresh preserves selection by stable ID")
	items.remove_at(18)
	list.set_items(items)
	suite.check(list.selected_index == 18 and list.get_selected().id == "0", "removed selections clamp to a remaining item")
	var picks:Array = []
	list.activated.connect(func(item): picks.append(item.payload))
	list.update(key(KEY_ENTER, true))
	list.update(key(KEY_ENTER))
	suite.equal(picks, [0], "list activation ignores repeats and carries the item's payload")
	suite.check(list.view().contains("[lb]x]"), "list escapes labels before adding selection BBCode")
	list.set_size(Vector2i(1, 1))
	suite.check(list.view().contains(">"), "one-column list keeps the selection marker")
	list.set_size(Vector2i.ZERO)
	suite.equal(list.view(), "", "zero-sized list renders nothing")
	list.set_items([])
	list.update(key(KEY_END))
	list.update(key(KEY_ENTER))
	suite.check(list.get_selected() == null and picks == [0], "empty list navigation cannot activate an item")
	list._dispose()

func _test_entry(suite) -> void:
	var entry = Entry.new()
	entry.set_size(Vector2i(4, 1))
	entry.set_focused(true)
	entry.insert_text("abcd")
	entry.update(key(KEY_LEFT))
	entry.update(key(KEY_NONE, false, "é".unicode_at(0)))
	suite.check(entry.text == "abcéd" and entry.caret == 4, "text entry inserts Unicode at its caret")
	entry.update(key(KEY_BACKSPACE))
	entry.update(key(KEY_DELETE))
	suite.equal(entry.text, "abc", "Backspace and Delete remove codepoints on either side")
	entry.update(key(KEY_HOME))
	entry.update(key(KEY_V, false, 0, false, false, true))
	suite.equal(entry.text, "é [x] !abc", "Cmd+V normalizes line breaks and tabs in pasted text")
	entry.update(key(KEY_END))
	suite.check(entry.caret == entry.text.length() and entry.view().contains("[bgcolor="), "horizontal scrolling keeps the end caret visible")
	var label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.text = entry.view()
	suite.check(label.get_parsed_text().length() == 4, "entry renders within its width including the caret cell")
	entry.set_size(Vector2i(30, 1))
	entry.set_text("[color=red]")
	suite.check(entry.view().contains("[lb]color=red]"), "entry escapes editable text")
	var submitted:Array = []
	var cancels:Array = []
	entry.submitted.connect(func(text): submitted.append(text))
	entry.cancelled.connect(func(): cancels.append(true))
	entry.update(key(KEY_ENTER, true))
	entry.update(key(KEY_ENTER))
	entry.update(key(KEY_ESCAPE, true))
	entry.update(key(KEY_ESCAPE))
	suite.check(submitted == ["[color=red]"] and cancels == [true], "text submission and cancellation fire once per press")
	entry.set_focused(false)
	suite.check(not entry.view().contains("[bgcolor=") and not entry.update(key(KEY_BACKSPACE)), "unfocused entry hides its caret and ignores input")
	entry.set_size(Vector2i.ZERO)
	suite.equal(entry.view(), "", "zero-sized entry renders nothing")
	label.free()
	entry._dispose()

func _test_confirmation(suite) -> void:
	var confirm = TUI.Confirmation.new("Delete [item]?\nSecond line")
	confirm.set_size(Vector2i(40, 3))
	confirm.set_focused(true)
	var answers:Array = []
	confirm.resolved.connect(func(value): answers.append(value))
	for code in [KEY_Y, KEY_ENTER, KEY_N, KEY_ESCAPE]:
		confirm.update(key(code, true))
		confirm.update(key(code))
	suite.equal(answers, [true, true, false, false], "confirmation resolves Yes/No keys without repeat actions")
	suite.check(confirm.view().contains("[lb]item]"), "confirmation escapes its prompt")
	confirm.set_size(Vector2i(5, 1))
	suite.equal(confirm.view(), "Delet", "confirmation respects narrow and short viewports")
	confirm._dispose()

func _test_flow(suite) -> void:
	var router = TUI.Router.new()
	router.set_size(Vector2i(40, 8))
	var root = Flow.ListScreen.new()
	router.push(root)
	router.update(key(KEY_ENTER))
	var editor = router.top()
	suite.check(editor is Flow.EditScreen and editor.entry.text == "Alpha", "documented flow opens an entry for the selected item")
	router.update(key(KEY_NONE, false, "Z".unicode_at(0)))
	router.update(key(KEY_ENTER))
	suite.check(router.top() is Flow.ConfirmScreen and editor.entry.text == "AlphaZ", "entry submission pushes a confirmation without losing text")
	router.update(key(KEY_N))
	suite.check(router.top() == editor and editor.entry.focused, "declining confirmation returns to the focused entry")
	router.update(key(KEY_ENTER))
	router.update(key(KEY_Y))
	suite.check(router.top() == root and root.list.get_selected().label == "AlphaZ", "confirmation result cascades through resume to update the retained list")
	router.update(key(KEY_ENTER))
	router.update(key(KEY_ESCAPE))
	suite.check(router.top() == root and root.list.get_selected().label == "AlphaZ", "cancelling text entry leaves the list unchanged")
	router.finish()

func _frames() -> void:
	for frame in 5: await (Engine.get_main_loop() as SceneTree).process_frame

func run_frames(suite) -> void:
	var console = Sh.Console.new()
	console.create_output()
	(Engine.get_main_loop() as SceneTree).root.add_child(console)
	console.size = Vector2(500, 260)
	var command = Command.new()
	console.context.scopes["screen_test"] = {"script": command}
	console.execute("screen_test")
	await _frames()
	suite.check(command.page.starts == 1 and console.is_busy, "ScreenCommand creates a root inside a real console session")
	var before = command.page.draws
	command.page.text = "asynchronous change"
	for i in 3: command.page.request_redraw()
	await _frames()
	suite.check(command.page.draws == before + 1 and console.active_tui.display.text == "asynchronous change", "external redraw requests coalesce into one frame")
	before = command.page.draws
	await _frames()
	suite.equal(command.page.draws, before, "screen adapter does not render while idle")
	command.page.pop("answer")
	await _frames()
	suite.check(command.result == "answer" and console.last_result.stdout.is_empty() and console.last_result.exit_code == 0, "root result is available without entering stdout")
	command.close_on_init = true
	console.execute("screen_test")
	await _frames()
	suite.check(not console.is_busy and command.result == "immediate" and command.page.finishes == 1, "a root can finish during initialization without leaving execution suspended")
	command.close_on_init = false
	command.invalid_root = true
	console.execute("screen_test")
	await _frames()
	suite.check(not console.is_busy and console.last_result.stderr.contains("fresh, unowned screen"), "invalid root reuse fails without acquiring an empty screen stack")
	command.invalid_root = false
	console.execute("screen_test")
	await _frames()
	var root = command.page
	var child = Page.new()
	root.push(child)
	await _frames()
	command._on_input(key(KEY_C, false, 0, false, true).payload)
	await _frames()
	suite.check(root.finishes == 1 and child.finishes == 1 and console.last_result.exit_code == 1, "Ctrl+C disposes the complete screen stack")
	console.execute("screen_test")
	await _frames()
	root = command.page
	console.context.scopes["screen_test"].clear()
	console.context.scopes.erase("screen_test")
	console.queue_free()
	await _frames()
	suite.check(root.finishes == 1 and command.router == null, "host removal cleans up the adapter's router")
