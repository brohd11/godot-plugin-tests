@tool
extends "res://tests/brohd/gdscript_parser/fixtures/gp_cycle_a.gd" #! ext ACycle
## Fixture: other half of the mutual-preload cycle. `extends ACycle` names a preload const declared
## BELOW the extends line, PATH forward-references P, and InnerB extends the preload const.

@warning_ignore_start("unused_variable")

const ACycle = preload("res://tests/brohd/gdscript_parser/fixtures/gp_cycle_a.gd")

const PATH = P
const P = "gp_cycle_b.gd"

var phase: ACycle.Phase

func _s_cycle_enum() -> void:
	if phase == ACycle.Phase.RUN: pass                          # anchor: "\tif phase == " (after)

class InnerB extends ACycle:
	const TAG2 = "inner_b"
