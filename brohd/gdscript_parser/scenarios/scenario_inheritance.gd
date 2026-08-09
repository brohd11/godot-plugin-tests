@tool
extends GpDerived
## Inheritance + inner-class + cross-script-alias web (à la the section under MainScript in the
## old test_comp.gd). This script `extends GpDerived`, so State / StateAlias / Handle are inherited
## from GpBase; it also reaches GpWidgets both by global class name and by preload alias.

@warning_ignore_start("unassigned_variable", "unused_variable", "standalone_expression", "unused_parameter", "unreachable_code", "confusable_local_declaration")

const Widgets = preload("res://tests/brohd/gdscript_parser/fixtures/gp_widgets.gd")

func _s_inherited_enum() -> void:
	var st := make_state()                                    # inherited method -> State
	if st == State.IDLE: pass                                 # anchor: "\tif st == " (after)

func _s_inherited_alias() -> void:
	var sa: StateAlias                                        # inherited const alias to State
	if sa == StateAlias.ACTIVE: pass                          # anchor: "\tif sa == " (after)

func _s_inherited_inner() -> void:
	var mo: Handle.Mode                                       # inherited inner-class enum
	if mo == Handle.Mode.OPEN: pass                           # anchor: "\tif mo == " (after)

func _s_cross_global() -> void:
	var kind := GpWidgets.new().get_kind()
	if kind == GpWidgets.Kind.PANEL: pass                     # anchor: "\tif kind == " (after)

func _s_cross_preload() -> void:
	var kind2 := Widgets.new().get_kind()
	if kind2 == Widgets.Kind.PANEL: pass                      # anchor: "\tif kind2 == " (after)

func _s_match_inherited(st: State) -> void:
	match st:
		State.IDLE: pass                                      # anchor: "\t\tState.IDLE" (before)

func _s_inner_arg() -> void:
	GpWidgets.Group.take(GpWidgets.K.PANEL)                   # anchor: "GpWidgets.Group.take(" (after)
