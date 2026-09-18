extends "res://addons/addon_lib/gdsh/src/tui/tui_command.gd"
## Test-only list command; the public example lives in GDSh _export_ignore/docs/tui.md.
var _selected:=0
var _first:=0
var _scroll_remainder:=0.0
var _items:Array[String] = []


static func get_command_name() -> String:
	return "test_tui_list"


static func get_self_command_data() -> Dictionary:
	return _command_data({&"help": "Open a selectable list in an interactive console.\nArrows/Page Up/Page Down/Home/End navigate; Enter selects; Escape/Ctrl+C cancel."})


func update(message:TUIMsg) -> void:
	match message.type:
		TUIMsg.Type.INIT:
			_items.clear()
			for index in 100:
				_items.append("Item %03d" % (index + 1))
			_selected = 0
			_first = 0
			_scroll_remainder = 0
			hint = "↑↓ Move · PgUp/Dn · Home/End · Enter Select · Esc/^C Cancel"
		TUIMsg.Type.RESIZE:
			_reveal_selected()
		TUIMsg.Type.MOUSE:
			var event = message.payload
			var delta:=0.0
			if event is InputEventPanGesture:
				delta = event.delta.y * 3
			elif event is InputEventMouseButton and event.pressed:
				if event.button_index == MOUSE_BUTTON_WHEEL_DOWN: delta = event.factor * 3
				elif event.button_index == MOUSE_BUTTON_WHEEL_UP: delta = -event.factor * 3
			_scroll_remainder += delta
			var steps = int(_scroll_remainder)
			_scroll_remainder -= steps
			_first = clampi(_first + steps, 0, maxi(0, _items.size() - _page_size()))
		TUIMsg.Type.KEY:
			var event:InputEventKey = message.payload
			if not event.pressed:
				return
			match event.keycode:
				KEY_ESCAPE: quit(ExitCode.FAIL)
				KEY_ENTER, KEY_KP_ENTER:
					if not event.echo:
						context.append_output(_items[_selected])
						quit()
				KEY_UP: _selected -= 1
				KEY_DOWN: _selected += 1
				KEY_PAGEUP: _selected -= _page_size()
				KEY_PAGEDOWN: _selected += _page_size()
				KEY_HOME: _selected = 0
				KEY_END: _selected = _items.size() - 1
				_: return
			_selected = clampi(_selected, 0, _items.size() - 1)
			_reveal_selected()


func _page_size() -> int:
	return maxi(1, viewport_size.y)


func _reveal_selected() -> void:
	_first = clampi(_first, maxi(0, _selected - _page_size() + 1), _selected)
	_first = mini(_first, maxi(0, _items.size() - _page_size()))


func view() -> String:
	var lines:PackedStringArray = []
	for index in range(_first, mini(_items.size(), _first + viewport_size.y)):
		var label = _items[index].replace("[", "[lb]")
		lines.append("[bgcolor=#38577a][color=#ffffff]> %s[/color][/bgcolor]" % label
				if index == _selected else "  " + label)
	return "\n".join(lines)
