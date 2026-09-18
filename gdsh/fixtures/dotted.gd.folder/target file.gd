@tool
class_name GDShAccessFixture
extends "res://tests/gdsh/fixtures/access_base.gd"
const Scalar = 12
const Alias = preload("res://tests/gdsh/fixtures/access_leaf.gd")
static var calls:int = 0
static func answer() -> int:
	calls += 1
	return 7
class Inner:
	static func answer() -> int:
		return 42
	class Nested:
		static func answer() -> int:
			return 84
