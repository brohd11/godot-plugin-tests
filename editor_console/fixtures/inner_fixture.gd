extends RefCounted
static func answer() -> int:
	return 42

class Nested:
	static func answer() -> int:
		return 84
