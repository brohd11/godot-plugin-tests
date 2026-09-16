extends RefCounted

#! inline
static func twice(value:int) -> int:
	return value * 2

static func sample(value:int) -> int:
	return twice(value) + 1
