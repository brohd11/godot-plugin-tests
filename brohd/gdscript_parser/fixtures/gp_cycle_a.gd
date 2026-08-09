@tool
extends RefCounted
## Fixture: one half of a mutual-preload cycle (gp_cycle_a <-> gp_cycle_b), distilled from
## plugin_dev_test_scripts/test_enum.gd / test_enum_pre.gd. The parser must resolve members
## across the cycle without looping.

@warning_ignore_start("unused_variable")

const BCycle = preload("res://tests/brohd/gdscript_parser/fixtures/gp_cycle_b.gd")

enum Phase { IDLE, RUN }

static var registry: Dictionary[String, BCycle] = {}

class InnerA:
	const TAG = "inner_a"
