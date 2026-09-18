extends "res://tests/gdsh/fixtures/node_base.gd"
signal own_signal(value:int)
signal _private_signal
const OWN_VALUE = 20
const _PRIVATE_VALUE = 30
enum State { IDLE, ACTIVE }
@export_category("Target Category")
@export_group("Target Group")
@export var own_value:int = 6
var _private_value:int = 7

static func own_static(value:int = 5) -> int:
	return value * 3

func own_method(value:int = 2) -> int:
	return own_value + value

func describe(value:int = 200) -> String:
	return "child:%d" % value

func _secret(value:int = 9) -> int:
	return value

func _get_property_list() -> Array[Dictionary]:
	return [
		{"name": "Live Group", "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP},
		{"name": "dynamic_value", "type": TYPE_INT, "usage": PROPERTY_USAGE_DEFAULT},
	]

func _get(property:StringName) -> Variant:
	return 42 if property == &"dynamic_value" else null
