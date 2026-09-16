extends RefCounted

class Payload:
	var value:int = 7

static func make() -> Payload:
	return Payload.new()
