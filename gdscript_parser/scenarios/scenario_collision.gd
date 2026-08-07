@tool
extends RefCounted
## Cross-script instance-method-argument completion where the caller has its OWN inner class named
## `Inner` (with an `enum Mode`) that collides with GpKitBase.Inner. The finder must produce the
## caller-reachable path (via the derived global class) - never the caller's own colliding Inner.

@warning_ignore_start("unassigned_variable", "unused_variable", "standalone_expression", "unused_parameter", "unreachable_code", "confusable_local_declaration")

# Deliberate name collision with GpKitBase.Inner / its Mode enum (like test_comp vs new_script).
class Inner:
	enum Mode { A, B }

# Decoy bare inner class colliding with GpKitBase.Sig (the print_debug.gd `S` shape).
class Sig:
	const DEBUG = &"x"

const mine = Inner.Mode  # local alias to the *caller's* Inner.Mode (a decoy for the finder)

func _s_calls() -> void:
	var n := GpKitDerived.new()
	var ic := n.Inner.new()
	n.tf_simple(GpKitDerived.MT.Unit.CM, GpKitDerived.MU.CM)  # anchor: "\tn.tf_simple(" (after)
	ic.use_mode(GpKitDerived.Inner.Mode.A)                    # anchor: "\tic.use_mode(" (after)
	ic.use_outer(GpKitDerived.Bundle.Layer.Tag.ONE)          # anchor: "\tic.use_outer(" (after)
	n.emit(GpKitDerived.Sig.new())                           # anchor: "\tn.emit(" (after)
