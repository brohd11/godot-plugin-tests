@tool
extends "res://tests/brohd/gdscript_parser/scenarios/scenario_anon_base.gd"
## Caller half of the new_ins repro (mirrors new_ins.gd): the object arrives from an INHERITED
## method, and the only reach to its script is an INHERITED preload const - so the caller's own
## scope holds nothing that names the type. The assigned var's type is a bare inner class, which
## lives in inner_classes rather than constants.

@warning_ignore_start("unused_variable", "confusable_local_declaration")

# Untyped `var` on both hops, exactly as new_ins.gd writes it - that is what leaves the caller's
# access object as bare `self`, so no as-typed candidate exists and the const search has to find it.
func _anon_inherited() -> void:
	var a = get_anon()
	var p = a.make()
	p = null                                                  # anchor: "\tp = " (after)

func _anon_inherited_deep() -> void:
	var a = get_anon()
	var d = a.make_deep()
	d = null                                                  # anchor: "\td = " (after)
