extends SceneTree

const Dispatcher = preload("res://addons/addon_lib/brohd/alib_runtime/misc/syntax_highlighters/text/dispatcher.gd")
const TextHighlighter = preload("res://addons/addon_lib/brohd/alib_runtime/misc/syntax_highlighters/text/text_syntax_highlighter.gd")
const Palette = preload("res://addons/addon_lib/brohd/alib_runtime/misc/syntax_highlighters/text/palette.gd")
var checks := 0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func check(condition:bool, label:String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + label)


func _run() -> void:
	var present:bool = ProjectSettings.get_setting("test/provider_present", false)
	var supported = Dispatcher.get_supported_extensions()
	for extension in ["txt", "md", "cfg", "ini", "log", "json", "yml", "yaml", "toml", "xml"]:
		check(Dispatcher.supports(extension) and extension in supported, "bundled format remains supported: " + extension)
		check(Dispatcher.get_highlighter(extension) is RefCounted, "bundled format returns logic: " + extension)
	check(not Dispatcher.supports("unknown"), "unknown format not supported")
	check(Dispatcher.get_highlighter("unknown") == null, "unknown format returns null")
	check(("gdsh" in supported) == present, "extension list reflects optional provider")
	check(supported.size() == (11 if present else 10), "extension list has no duplicates")
	for extension in ["gdsh", ".gdsh", "GDSH", ".GdSh", "res://scripts/example.GDSH"]:
		check(Dispatcher.normalize(extension) == "gdsh", "normalize gdsh request: " + extension)
		check(Dispatcher.supports(extension) == present, "availability matches provider: " + extension)
		var logic = Dispatcher.get_highlighter(extension)
		if not present:
			check(logic == null, "missing provider returns null: " + extension)
			continue
		check(logic is RefCounted, "optional provider is RefCounted: " + extension)
		if logic == null:
			continue
		check(logic != Dispatcher.get_highlighter(extension), "provider instances are fresh")
		for method in ["setup", "get_line_highlighting", "clear_cache"]:
			check(logic.has_method(method), "optional provider implements: " + method)
		var edit = TextEdit.new()
		edit.text = 'echo "first\nsecond"'
		var palette = Palette.new()
		palette.string = Color.ORANGE
		logic.setup(edit, palette)
		check(logic.get_line_highlighting(1)[0].color == Color.ORANGE, "ALib palette and out-of-order multiline lookup work")
		edit.text = "echo first\nsecond"
		logic.clear_cache()
		check(logic.get_line_highlighting(1)[0].color == palette.function, "ALib contract clears stale multiline state")
		edit.free()
	var wrapper = TextHighlighter.new()
	wrapper.set_file_path("res://example.gdsh")
	var edit = TextEdit.new()
	edit.text = 'echo "text"'
	edit.syntax_highlighter = wrapper
	root.add_child(edit)
	var spans = wrapper.get_line_syntax_highlighting(0)
	if present:
		check(not spans.is_empty(), "ALib text wrapper uses optional provider")
		var replacement = Palette.new()
		replacement.function = Color.RED
		wrapper.palette = replacement
		check(wrapper.get_line_syntax_highlighting(0)[0].color == Color.RED, "wrapper palette updates reach provider")
	else:
		check(spans.is_empty(), "ALib text wrapper falls back to plain text without GDSh")
		check(Dispatcher.get_highlighter("gdsh") == null, "repeated missing provider lookup remains harmless")
	edit.free()
	print("ALib text dispatch (%s): %d checks, %d failures" % ["GDSh present" if present else "GDSh absent", checks, failures])
	quit(0 if failures == 0 else 1)
