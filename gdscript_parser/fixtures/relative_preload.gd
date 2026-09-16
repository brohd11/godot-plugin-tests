extends RefCounted

const Relative = preload("relative_payload.gd")
const Inner = preload("relative_payload.gd").Payload

static func value() -> int:
	var item:Inner = Relative.make()
	return item.value
