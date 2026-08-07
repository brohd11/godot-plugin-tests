@tool
class_name InfSupport
extends RefCounted
## Fixture for scenario_inference.gd: a self-contained global class mirroring the project globals
## that test_comp.gd::test_infer_dict leaned on (AutoloadScene / SomeClass / TEnum.NestedTest).
## Exposes a typed const, a typed dict, a color const, a signal + a func returning that signal, an
## inner class with a static enum-returning func referenced as a Callable, and string/int accessors.

@warning_ignore_start("unused_parameter", "unused_variable", "standalone_expression")

const INT_2 := 2
const TYPED_DICT: Dictionary[String, int] = {"a": 1}
const MY_COLOR := Color.RED

signal sig_bool(flag: bool)

class Nested:
	static func node_test(m: Node.ProcessMode) -> Node.ProcessMode:
		return m

# Untyped return that yields a Signal (inference must read the returned signal member).
func get_signal():
	return sig_bool

func get_string(v := "") -> String:
	return ""

func get_int() -> int:
	return 1

static func static_get_string() -> String:
	return ""
