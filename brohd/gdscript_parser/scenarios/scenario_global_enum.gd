@tool
extends "res://tests/brohd/gdscript_parser/fixtures/gp_enum_base.gd"
## Enum typing across every kind of enum and every way a value acquires one.
##
## THE KINDS (three separate resolution paths, and they do NOT share code):
##   script-declared  GpBase.State        -> "res://gp_base.gd::State##Enum"   (absolute path)
##   @GlobalScope     Error, Key          -> "Error##Enum"                     (is_global_enum)
##   ClassDB class    Node.ProcessMode    -> "Node::ProcessMode##Enum"         (class_has_enum)
##
## THE SHAPES (local var / member var / func arg / declared return / match / const / inherited / inner
## class). Only the local-var shape was ever tested; that is precisely why the other shapes could all
## regress for @GlobalScope enums while everything looked green.
##
## Everything downstream keys off the type ending in "##Enum" - enum_completion._process_identifier()
## bails immediately without it.

const GpBase = preload("res://tests/brohd/gdscript_parser/fixtures/gp_base.gd")

@warning_ignore_start("unused_variable", "standalone_expression", "unused_parameter", "unassigned_variable")

var _member_err: Error = OK
var _member_state: GpBase.State = GpBase.State.IDLE
var _member_pm: Node.ProcessMode = Node.PROCESS_MODE_ALWAYS

const CONST_ERR: Error = OK
const CONST_ERR_INFERRED := FAILED


# --- @GlobalScope enum (Error) ---------------------------------------------------------------
func _s_local_err() -> void:
	var e: Error = OK
	if e == OK: pass                      # anchor: "\tif e == " (after)

func _s_member_err() -> void:
	if _member_err == OK: pass            # anchor: "\tif _member_err == " (after)

func take_err(e: Error) -> void:
	pass

func _s_arg_err() -> void:
	take_err(OK)                          # anchor: "\ttake_err(" (after)

func returns_err() -> Error:
	return OK

func _s_return_err() -> void:
	var r := returns_err()
	if r == OK: pass                      # anchor: "\tif r == " (after)

func _s_match_err(e: Error) -> void:
	match e:
		OK: pass                          # anchor: "\t\tOK: pass" (before)

func _s_const_err() -> void:
	if CONST_ERR == OK: pass              # anchor: "\tif CONST_ERR == " (after)

func _s_const_err_inferred() -> void:
	if CONST_ERR_INFERRED == OK: pass     # anchor: "\tif CONST_ERR_INFERRED == " (after)

# inherited from gp_enum_base.gd
func _s_inherited_member_err() -> void:
	if _base_err == OK: pass              # anchor: "\tif _base_err == " (after)

func _s_inherited_arg_err() -> void:
	base_takes_err(OK)                    # anchor: "\tbase_takes_err(" (after)

func _s_inherited_return_err() -> void:
	var br := base_returns_err()
	if br == OK: pass                     # anchor: "\tif br == " (after)

# member of an INNER class, reached through an instance
class Holder:
	var inner_err: Error = OK

func _s_inner_class_member_err() -> void:
	var h := Holder.new()
	if h.inner_err == OK: pass            # anchor: "\tif h.inner_err == " (after)


# --- ClassDB class enum (Node.ProcessMode) ---------------------------------------------------
func _s_local_pm() -> void:
	var pm: Node.ProcessMode = Node.PROCESS_MODE_ALWAYS
	if pm == Node.PROCESS_MODE_ALWAYS: pass   # anchor: "\tif pm == " (after)

func _s_member_pm() -> void:
	if _member_pm == Node.PROCESS_MODE_ALWAYS: pass   # anchor: "\tif _member_pm == " (after)

func take_pm(pm: Node.ProcessMode) -> void:
	pass

func _s_arg_pm() -> void:
	take_pm(Node.PROCESS_MODE_ALWAYS)     # anchor: "\ttake_pm(" (after)

func returns_pm() -> Node.ProcessMode:
	return Node.PROCESS_MODE_ALWAYS

func _s_return_pm() -> void:
	var rp := returns_pm()
	if rp == Node.PROCESS_MODE_ALWAYS: pass   # anchor: "\tif rp == " (after)

func _s_inherited_member_pm() -> void:
	if _base_pm == Node.PROCESS_MODE_ALWAYS: pass   # anchor: "\tif _base_pm == " (after)

# an integer constant that BELONGS to a builtin-class enum (Vector2.Axis). KNOWN GAP - see global_enum.gd.
func _s_class_int_const() -> void:
	var axis := Vector2.AXIS_X
	if axis == Vector2.AXIS_X: pass       # anchor: "\tif axis == " (after)

# An engine PROPERTY backed by an enum. The api dump types it "int" and carries no hint; the enum is
# only recoverable from the property's GETTER (get_process_mode -> enum::Node.ProcessMode).
func _s_instance_prop() -> void:
	var n := Node.new()
	if n.process_mode == Node.PROCESS_MODE_ALWAYS: pass   # anchor: "\tif n.process_mode == " (after)

# Same property read off a DERIVED class: process_mode is declared on Node, so this only resolves by
# walking ClassDB parents - the same walk the ~88 properties with parent-declared getters need.
func _s_inherited_prop() -> void:
	var sp := Sprite2D.new()
	if sp.process_mode == Node.PROCESS_MODE_ALWAYS: pass  # anchor: "\tif sp.process_mode == " (after)

# The SETTER's argument is enum::Node.ProcessMode in the api dump. Builtin method args reach the
# completion layer WITHOUT passing through the type resolver, so this is the one path where the api's
# raw "enum::" notation used to leak out instead of a type path.
func _s_prop_setter_arg() -> void:
	var n2 := Node.new()
	n2.set_process_mode(Node.PROCESS_MODE_ALWAYS)   # anchor: "\tn2.set_process_mode(" (after)

# The matching GETTER call: its return type is enum::Node.ProcessMode as well.
func _s_method_return() -> void:
	var n4 := Node.new()
	var pm2 := n4.get_process_mode()
	if pm2 == Node.PROCESS_MODE_ALWAYS: pass    # anchor: "\tif pm2 == " (after)

# CONTROL: an ordinary property whose getter returns no enum must be untouched by the getter lookup.
func _s_plain_prop() -> void:
	var n3 := Node.new()
	if n3.name == "x": pass               # anchor: "\tif n3.name == " (after)


# --- script-declared enum: the control -------------------------------------------------------
func _s_local_state() -> void:
	var s: GpBase.State = GpBase.State.IDLE
	if s == GpBase.State.IDLE: pass       # anchor: "\tif s == " (after)

func _s_member_state() -> void:
	if _member_state == GpBase.State.IDLE: pass   # anchor: "\tif _member_state == " (after)

func take_state(s: GpBase.State) -> void:
	pass

func _s_arg_state() -> void:
	take_state(GpBase.State.IDLE)         # anchor: "\ttake_state(" (after)

func returns_state() -> GpBase.State:
	return GpBase.State.IDLE

func _s_return_state() -> void:
	var rs := returns_state()
	if rs == GpBase.State.IDLE: pass      # anchor: "\tif rs == " (after)

func _s_match_state(s: GpBase.State) -> void:
	match s:
		GpBase.State.IDLE: pass           # anchor: "\t\tGpBase.State.IDLE: pass" (before)
