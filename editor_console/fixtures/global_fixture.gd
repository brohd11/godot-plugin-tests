class_name EditorConsoleMigrationFixture
extends RefCounted
static var calls:int = 0
const Inner = preload("res://tests/editor_console/fixtures/inner_fixture.gd")

static func greeting(name:String) -> String:
	calls += 1
	return "hello " + name

static func add(a:int, b:int = 2) -> int:
	return a + b
