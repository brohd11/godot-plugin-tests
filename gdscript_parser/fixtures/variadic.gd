extends RefCounted

static func sample(first:int = 7, ...rest:Array) -> Array:
	return [first, rest]

static func implicit(...rest) -> Array:
	return rest
