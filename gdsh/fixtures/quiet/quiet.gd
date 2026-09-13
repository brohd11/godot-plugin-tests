extends GDSh.CommandBase

static func get_command_name():
	return "quiet"

static func get_self_command_data():
	return _command_data({&"help": "Non-discoverable command fixture", &"discoverable": false})

func _execute(ctx:Context):
	ctx.append_output("quiet ran")
