extends Node
signal base_signal
const BASE_VALUE = 10
var base_value:int = 4

static func base_static(value:int = 2) -> int:
	return value * 2

func base_method(value:int = 3) -> int:
	return value + base_value

func describe(value:int = 100) -> String:
	return "base:%d" % value
