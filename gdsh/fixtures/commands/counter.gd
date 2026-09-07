extends GDSh.CommandBase

static var calls = 0

static func get_command_name():
	return "counter"

static func get_self_command_data():
	return _command_data({&"help": "Count execution calls"})

func _execute(ctx:Context):
	calls += 1
	ctx.append_output(str(calls))
