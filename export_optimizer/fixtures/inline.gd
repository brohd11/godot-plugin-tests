extends RefCounted

#! inline
static func twice(value:int) -> int:
	return value * 2

static func sample(value:int) -> int:
	return twice(value) + 1

static func dynamic_sample(value:Variant) -> int:
	return 1 + twice(value)

#! inline
static func is_parented(node:Node) -> bool:
	return node.is_inside_tree()

static func reference_sample(node:Node) -> bool:
	return true and is_parented(node)

#! inline
static func early_value(value:int) -> int:
	if value < 0:
		return -1
	if value == 0:
		return 2
	return value + 3

#! inline
static func early_effect(events:Array, value:int) -> void:
	if value < 0:
		events.append("early")
		return
	events.append(value)

static func early_check() -> Array:
	var events:Array = []
	var total:int = 0
	for value:int in range(-1, 2):
		var result := early_value(value)
		total += result
		early_effect(events, value)
		events.append("after")
	return [total, events]
