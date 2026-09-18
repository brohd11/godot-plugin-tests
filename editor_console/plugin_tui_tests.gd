extends RefCounted
const Sh = preload("res://addons/addon_lib/gdsh/_ns/gd_sh.gd")

class EditorRouter extends "res://addons/editor_console/src/default_commands/editor/editor.gd":
	var program
	func _get_commands() -> Dictionary:
		return {"plugin": {&"get_command": func(): return program}}

class Plugins extends "res://addons/editor_console/src/default_commands/editor/plugin/plugin.gd":
	var directory:String
	var states:Dictionary = {}
	var calls:Array = []
	var reject:=false
	var available:=true
	func _get_commands() -> Dictionary:
		return preload("res://addons/editor_console/src/default_commands/editor/plugin/plugin.gd").new().get_commands()
	func _editor_available() -> bool: return available
	func _addons_path() -> String: return directory
	func _host_plugin_id() -> String: return "host"
	func _is_enabled(id:String) -> bool: return states.get(id, false)
	func _set_enabled(id:String, enabled:bool) -> void:
		calls.append([id, enabled])
		if not reject: states[id] = enabled


func _frames() -> void:
	for frame in 4: await (Engine.get_main_loop() as SceneTree).process_frame


func _key(program, code:int, echo:=false) -> void:
	var event = InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.echo = echo
	program.post_message(Sh.TUIMsg.new(Sh.TUIMsg.Type.KEY, event))
	await _frames()


func _fixture(root:String, id:String, name:String, valid:=true) -> void:
	var directory = root.path_join(id)
	DirAccess.make_dir_recursive_absolute(directory)
	var config = ConfigFile.new()
	config.set_value("plugin", "name", name)
	config.set_value("plugin", "script", "plugin.gd")
	config.save(directory.path_join("plugin.cfg"))
	if valid:
		var file = FileAccess.open(directory.path_join("plugin.gd"), FileAccess.WRITE)
		file.store_string("@tool\nextends EditorPlugin\n")


func _remove(root:String, id:String) -> void:
	var directory = root.path_join(id)
	for file in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(file))
	DirAccess.remove_absolute(directory)


func run(suite) -> void:
	var program = Plugins.new()
	program.directory = "user://plugin-tui-%s" % Time.get_ticks_usec()
	_fixture(program.directory, "alpha", "Alpha [test]")
	_fixture(program.directory, "host", "Renamed Console")
	_fixture(program.directory, "invalid", "Invalid", false)
	for index in 30:
		_fixture(program.directory, "row%02d" % index, "")
	DirAccess.make_dir_recursive_absolute(program.directory.path_join("not_a_plugin"))
	program.states.host = true
	var found = program._list_plugins()
	suite.check(found.size() == 33, "plugin discovery requires plugin.cfg in each immediate addon")
	var console = Sh.Console.new()
	console.create_output()
	(Engine.get_main_loop() as SceneTree).root.add_child(console)
	console.size = Vector2(600, 260)
	var router = EditorRouter.new()
	router.program = program
	console.context.scopes["editor"] = {"script": router}
	var cli = await console.execute("editor plugin enable alpha --enable --disable")
	suite.check(cli.stderr.contains("Cannot provide more than one flag") and console.active_tui == null,
		"editor plugin enable routes to the existing noninteractive command without acquiring a TUI")
	console.execute("editor plugin")
	await _frames()
	var display:RichTextLabel = console.active_tui.display
	suite.check(display.get_parsed_text().contains("Alpha [test]") and not display.get_parsed_text().contains("row29"), "plugin view escapes names and renders a viewport slice")
	suite.check(not display.scroll_active and display.get_v_scroll_bar().value == 0, "plugin view has no native scrollbar or scroll offset")
	await _key(program, KEY_ENTER)
	suite.check(program.states.alpha and program.calls == [["alpha", true]] and console.is_busy, "Enter enables a plugin without closing its TUI")
	suite.check(display.get_parsed_text().contains("enabled   Alpha"), "plugin view refreshes enabled state after a toggle")
	await _key(program, KEY_ENTER, true)
	suite.check(program.calls.size() == 1, "held Enter never repeats a plugin toggle")
	await _key(program, KEY_ENTER)
	suite.check(not program.states.alpha and program.calls.size() == 2, "Enter disables an enabled plugin")
	program.reject = true
	await _key(program, KEY_ENTER)
	suite.check(not program.states.alpha and program.hint.contains("Could not change"), "plugin toggle failure reports actual unchanged status")
	program.reject = false
	await _key(program, KEY_DOWN)
	await _key(program, KEY_ENTER)
	suite.check(program.calls.size() == 3 and program.hint.contains("cannot disable itself"), "host addon is protected by identity despite renamed display name")
	await _key(program, KEY_DOWN)
	await _key(program, KEY_ENTER)
	suite.check(program.calls.size() == 3 and program.hint.contains("Missing plugin script"), "invalid plugin configuration stays visible and cannot be toggled")
	await _key(program, KEY_END)
	suite.check(display.get_parsed_text().contains("row29") and display.get_v_scroll_bar().value == 0, "plugin End updates its drawn viewport")
	_fixture(program.directory, "000first", "First")
	await _key(program, KEY_R)
	suite.check(program._screen.list.get_selected().id == "row29", "plugin refresh preserves selection by directory identifier")
	_remove(program.directory, "row29")
	await _key(program, KEY_ENTER)
	suite.check(program.calls.size() == 3 and program.hint.contains("disappeared"), "plugin removed before toggle produces feedback without touching another addon")
	for id in DirAccess.get_directories_at(program.directory):
		_remove(program.directory, id)
	await _key(program, KEY_R)
	await _key(program, KEY_ENTER)
	suite.check(display.get_parsed_text().contains("No addon") and console.is_busy, "empty plugin lists remain usable")
	await _key(program, KEY_ESCAPE)
	suite.check(not console.is_busy and console.last_result.exit_code == 0 and console.last_result.stdout.is_empty(), "plugin Escape exits successfully without dumping the view")
	program.available = false
	console.execute("editor plugin")
	await _frames()
	suite.check(not console.is_busy and console.last_result.exit_code != 0 and console.last_result.stderr.contains("editor services"), "plugin command reports unavailable editor services and restores the console")
	console.context.scopes["editor"].clear()
	console.context.scopes.erase("editor")
	console.queue_free()
	await _frames()
	DirAccess.remove_absolute(program.directory)
