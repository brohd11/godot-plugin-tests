@tool
class_name GpKitDerived
extends GpKitBase
## Derived global class: inherits Inner / Bundle / Meter / MT / MU / tf_simple from GpKitBase, so a
## caller can reach the base's members through the derived name (as with NewScript3 -> NewScript).

@warning_ignore_start("unused_parameter", "unused_variable", "standalone_expression")


# Calls the INHERITED tf_simple from inside the derived script. tf_simple's arg is spelled "MT.Unit"
# in GpKitBase's scope; because this script inherits GpKitBase it is reachable verbatim from here, so
# the access finder must offer it as-typed rather than prefixing it with an object path.
func _s_inherited_call() -> void:
	tf_simple(MT.Unit.CM, MU.CM)  # anchor: "\ttf_simple(" (after)
