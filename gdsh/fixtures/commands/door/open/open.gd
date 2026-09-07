extends GDSh.CommandBase

static func get_command_name():
	return "open"

static func get_self_command_data():
	return _command_data({&"help": "Open a named door", &"positional_count": 1})

func _execute(ctx:Context):
	ctx.append_output("opened:" + positional_args[0])

func _get_completions(completion:Completion):
	var options = Options.new()
	options.add_option("north")
	options.add_option("south")
	return options
