extends RefCounted
## Target for GDSh.Utils.Method tests; not a command.

static func add(a:int, b:int = 2) -> int:
	return a + b

static func length_of(value:Vector2) -> float:
	return value.length()

static func identity(value:Object) -> Object:
	return value

func greet(who:String) -> String:
	return "hello " + who
