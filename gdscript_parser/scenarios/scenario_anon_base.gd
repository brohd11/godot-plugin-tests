@tool
extends RefCounted
## Base half of the new_ins repro (mirrors editor_code_completion.gd): it owns the preload const for
## a script with no class_name, and hands the object out through a method. The caller inherits both.

const Anon = preload("res://tests/gdscript_parser/fixtures/gp_anon.gd")

func get_anon() -> Anon:
	return Anon.new()
