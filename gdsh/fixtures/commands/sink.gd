extends GDSh.CommandBase

static func get_command_name():
	return "sink"

static func get_self_command_data():
	return _command_data({&"help": "Echo stdin"})

func _execute(ctx:Context):
	ctx.append_output("stdin:" + ctx.stdin)
	ctx.append_error("sink diagnostic")
