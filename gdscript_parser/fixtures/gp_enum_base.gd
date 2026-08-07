@tool
extends RefCounted
## Base for scenario_global_enum: holds enum-typed members / args / returns so the derived script can
## reach them through INHERITANCE. Every enum bug found so far (declaring script, origin, the ##Enum
## marker) hid behind inheritance, so the enum shapes are worth testing across it too.

@warning_ignore_start("unused_parameter", "unused_variable", "standalone_expression")

var _base_err: Error = OK
var _base_pm: Node.ProcessMode = Node.PROCESS_MODE_ALWAYS


func base_takes_err(e: Error) -> void:
	pass


func base_returns_err() -> Error:
	return OK
