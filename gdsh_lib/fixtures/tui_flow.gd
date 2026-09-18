extends GDShTUI.ScreenCommand
const TUI = preload("res://addons/addon_lib/gdsh_lib/tui/manifest.gd").TUI

class ConfirmScreen extends TUI.Screen:
	var confirmation:TUI.Confirmation
	func _init(value:String) -> void:
		confirmation = TUI.Confirmation.new("Use this value?\n" + value)
		add_component(confirmation)
		confirmation.resolved.connect(_answer)
	func _answer(accepted:bool) -> void:
		pop(accepted)
	func set_size(value:Vector2i) -> void:
		super(value)
		confirmation.set_size(size)
	func view() -> String:
		return confirmation.view()

class EditScreen extends TUI.Screen:
	var entry:TUI.TextEntry
	func _init(value:String) -> void:
		entry = TUI.TextEntry.new(value, "Item name")
		add_component(entry)
		entry.submitted.connect(_submit)
		entry.cancelled.connect(_cancel)
	func _submit(value:String) -> void:
		push(ConfirmScreen.new(value))
	func _cancel() -> void:
		pop()
	func resume(accepted:Variant) -> void:
		if accepted == true: pop(entry.text)
	func set_size(value:Vector2i) -> void:
		super(value)
		entry.set_size(Vector2i(size.x, mini(1, size.y)))
	func view() -> String:
		return entry.view()

class ListScreen extends TUI.Screen:
	var list = TUI.List.new()
	func _init() -> void:
		add_component(list)
		list.set_items([
			TUI.List.Item.new("alpha", "Alpha"),
			TUI.List.Item.new("beta", "Beta"),
		])
		list.activated.connect(_edit)
		hint = "↑↓ Move · Enter Edit · Esc Exit"
	func _edit(item:TUI.List.Item) -> void:
		push(EditScreen.new(item.label))
	func resume(value:Variant) -> void:
		if value is String:
			list.get_selected().label = value
			list.set_items(list.items)
	func set_size(value:Vector2i) -> void:
		super(value)
		list.set_size(size)
	func view() -> String:
		return list.view()

static func get_command_name() -> String:
	return "edit_list"

static func get_self_command_data() -> Dictionary:
	return _command_data({&"help": "Edit an in-memory list using stacked screens"})

func create_screen() -> Screen:
	return ListScreen.new()
