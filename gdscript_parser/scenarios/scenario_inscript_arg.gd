@tool
extends RefCounted
## In-script dual-arg completion: the object (Holder) is an inner class of THIS script, and its
## method args are typed by a script-level const alias / a dotted global-class path - both written in
## this script's own scope. The finder must offer the arg symbol AS-TYPED (reachable from here),
## never prefix it with the object's own name (Holder.*), which is the TnumClass case in test_comp.gd.

@warning_ignore_start("unused_parameter", "unused_variable", "standalone_expression", "unreachable_code")

const StateRef = GpBase.State  # script-level alias to a cross-script enum (mirrors TNumNum)

class Holder:
	static func take(s: StateRef) -> void:      # arg typed by the outer script's const alias
		pass

	static func take2(s: GpBase.State) -> void: # arg typed by a dotted global-class path
		pass

func _calls() -> void:
	var h := Holder.new()
	h.take(StateRef.IDLE)         # anchor: "\th.take(" (after) -> expect StateRef, not Holder.StateRef
	h.take2(GpBase.State.IDLE)    # anchor: "\th.take2(" (after) -> expect GpBase.State, not Holder.GpBase.State
