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
