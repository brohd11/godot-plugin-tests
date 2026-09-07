extends GDSh.CommandBase

static func get_command_name():
	return "door"

static func get_self_command_data():
	return _command_data({&"help": "Choose a door action"})
