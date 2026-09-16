@tool
class_name GpKitBase
extends RefCounted
## Fixture for the cross-script instance-method-argument cases. Mirrors NewScript: an inner class
## whose name deliberately collides with the caller's own inner class, an OUTER nested chain reached
## from the inner class's scope, and a deeply-nested enum with const aliases + a tf_simple method
## (the tf_test_simple analog). GpKitDerived extends this so callers reach it all by a derived name.

@warning_ignore_start("unused_parameter", "unused_variable", "standalone_expression")

class Inner:
	enum Mode { A, B }

	func use_mode(m: Mode) -> void:
		pass

	func use_outer(n: Bundle.Layer.Tag) -> void:
		pass

class Bundle:
	class Layer:
		enum Tag { ONE, TWO }

class Meter:
	enum Unit { CM, MM }

const MT = Meter
const MU = Meter.Unit

func tf_simple(a: MT.Unit, b: MU) -> void:
	pass

# Bare inner class used directly as an arg type (like print_debug.gd's `S`): the finder must reach
# it as <caller-reach>.Sig, never the caller's own bare `Sig`.
class Sig:
	const DEBUG = &"d"
	const INFO = &"i"

func emit(s: Sig) -> void:
	pass
