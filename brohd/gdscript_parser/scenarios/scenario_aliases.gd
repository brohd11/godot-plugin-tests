@tool
extends RefCounted
## Cross-script "user-typed alias" matching. Reaches GpService's deeply-nested Timer.Scale enum
## via different spellings from *outside* the defining script: the full path, a caller-side alias,
## a method return, and a match block. Complements the in-script alias sites inside gp_service.gd.

@warning_ignore_start("unassigned_variable", "unused_variable", "standalone_expression", "unused_parameter", "unreachable_code", "confusable_local_declaration")

const Service = preload("res://tests/brohd/gdscript_parser/fixtures/gp_service.gd")
const Sc = GpService.Ticker.Scale  # caller-side alias for the nested enum
const Anon = preload("res://tests/brohd/gdscript_parser/fixtures/gp_anon.gd")  # no class_name -> alias is the ONLY reach

func _s_call_full() -> void:
	var s := Service.new()
	s.tf_full(GpService.Ticker.Scale.MSEC)                     # anchor: "\ts.tf_full(" (after)

func _s_call_caller_alias() -> void:
	var s := Service.new()
	s.tf_ts(Sc.MSEC)                                          # anchor: "\ts.tf_ts(" (after)

func _s_cross_return() -> void:
	var v := GpService.make()                                # returns Timer.Scale
	if v == GpService.Ticker.Scale.MSEC: pass                 # anchor: "\tif v == " (after)

func _s_match_cross(v: GpService.Ticker.Scale) -> void:
	match v:
		GpService.Ticker.Scale.MSEC: pass                     # anchor: "\t\tGpService.Ticker.Scale.MSEC" (before)

# The new_ins shape: assign to a var whose type is a bare inner class instance of a script with no
# class_name. Only `Anon` reaches it, so the chain must be alias + inner class path.
func _anon_inner_class() -> void:
	var a := Anon.new()
	var p := a.make()
	p = null                                                  # anchor: "\tp = " (after)

func _anon_inner_class_deep() -> void:
	var a := Anon.new()
	var d := a.make_deep()
	d = null                                                  # anchor: "\td = " (after)
