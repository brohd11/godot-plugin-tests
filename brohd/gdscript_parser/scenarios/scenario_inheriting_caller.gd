@tool
extends GpKitBase
## The caller ITSELF extends GpKitBase, and calls the inherited tf_simple on a *different* derived
## instance (GpKitDerived). Two candidate spellings of the arg type both resolve from here:
##
##   "MT.Unit"              - verbatim, because this script inherits GpKitBase and so owns MT
##   "GpKitDerived.MT.Unit" - through the object's path
##
## Only the candidate ORDER decides which one is offered, and that order is picked by the
## `secondary_in_caller_script` predicate in access.gd. A plain script-equality check answers "no"
## here (the declaring script is gp_kit_base, the caller is this file) and prefixes it needlessly;
## the reachability check answers "yes" and offers the shorter, as-typed spelling - matching how the
## in-script cases (scenario_inscript_arg) behave.

@warning_ignore_start("unused_parameter", "unused_variable", "standalone_expression")


func _s_calls() -> void:
	var n := GpKitDerived.new()
	n.tf_simple(MT.Unit.CM, MU.CM)  # anchor: "\tn.tf_simple(" (after)
