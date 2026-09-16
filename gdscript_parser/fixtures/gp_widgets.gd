@tool
class_name GpWidgets
extends RefCounted
## Fixture: mirrors AnotherTest - a global class (class_name) exposing enums, inner classes, const
## aliases (K / S), and an inner class whose const alias (GS) points at an outer const. Used for
## cross-script access + the `global` alias field.

@warning_ignore_start("unused_parameter", "unused_variable")

enum Kind { PANEL, BUTTON }
const K = Kind

class Board:
	enum Slot { LEFT, RIGHT }

const S = Board.Slot

class Group:
	const GS = K
	static func take(s: GS) -> void:
		pass

func get_kind() -> Kind:
	return Kind.PANEL

func get_slot() -> Board.Slot:
	return Board.Slot.LEFT
