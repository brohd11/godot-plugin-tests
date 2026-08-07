@tool
extends RefCounted
## Self-contained scenarios: inner-class enum via return (the original repro), distinct-name
## two-level nesting, same-name nesting (probe), a top-level enum, a match branch and a func arg.

@warning_ignore_start("unassigned_variable", "unused_variable", "standalone_expression", "unused_parameter", "unreachable_code", "confusable_local_declaration")

class GpAlert:
	enum AlertType { NONE, UPDATE, DEPENDENCY, ALL }

	func all_valid() -> AlertType:
		return AlertType.NONE

# Distinct-name two-level nesting: `Outer.Mid.MidNum` must stay full, not collapse.
class Outer:
	class Mid:
		enum MidNum { A, B }

# Legit same-name outer/inner. NOTE: the type resolver can't resolve an enum through a same-name
# nested class (out of scope), so this is only a probe; the finder never dedups regardless.
class DupName:
	class DupName:
		enum DupNum { A, B }

enum TopEnum { X, Y }

func _take_alert(a: GpAlert.AlertType) -> void:
	pass

func _s_repro() -> void:
	var ad := GpAlert.new()
	var alert := ad.all_valid()
	if alert == GpAlert.AlertType.ALL: pass                   # anchor: "\tif alert == " (after)

func _s_nested_two_level() -> void:
	var m: Outer.Mid.MidNum
	if m == Outer.Mid.MidNum.A: pass                          # anchor: "\tif m == " (after)

func _s_same_name() -> void:
	var n: DupName.DupName.DupNum
	if n == DupName.DupName.DupNum.A: pass                    # anchor: "\tif n == " (after)

func _s_self_top_enum() -> void:
	var t := TopEnum.X
	if t == TopEnum.Y: pass                                   # anchor: "\tif t == " (after)

func _s_match(alert: GpAlert.AlertType) -> void:
	match alert:
		GpAlert.AlertType.NONE: pass                          # anchor: "\t\tGpAlert.AlertType.NONE" (before)

func _s_func_arg() -> void:
	_take_alert(GpAlert.AlertType.NONE)                       # anchor: "\t_take_alert(" (after)
