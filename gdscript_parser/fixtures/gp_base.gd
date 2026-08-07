@tool
class_name GpBase
extends RefCounted
## Fixture: base of an inheritance chain (GpDerived extends this). Provides an enum, a const
## alias to it, and an inner class - all inheritable by subclasses for inherited-member search.

@warning_ignore_start("unused_parameter", "unused_variable")

enum State { IDLE, ACTIVE }
const StateAlias = State

class Handle:
	enum Mode { OPEN, CLOSED }

func make_state() -> State:
	return State.IDLE

func take_state(s: State) -> void:
	pass
