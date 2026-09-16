extends RefCounted
static var events:Array = []
var value:float:
	get:
		events.append("get")
		return 2.5
func _notification(what:int) -> void:
	if what == NOTIFICATION_PREDELETE:
		events.append("deleted")
static func make() -> RefCounted:
	events.append("make")
	return load("res://tests/gdscript_optimizer/fixtures/inline/events.gd").new()
static func change(values:Dictionary) -> float:
	events.append("change")
	values.value = 100.0
	return 3.0
