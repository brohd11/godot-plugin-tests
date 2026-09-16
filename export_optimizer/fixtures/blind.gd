extends RefCounted

const User = preload("user.gd")

static func read() -> int:
	return User.make_value().amount

