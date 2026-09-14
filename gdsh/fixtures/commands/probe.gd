extends GDSh.CommandBase

var mode = "default"
var loud = false

static func get_command_name():
	return "probe"

static func get_self_command_data():
	return _command_data({&"help": "Inspect routed arguments", &"positional_count": "min:0"})

func _get_flags() -> Dictionary:
	var options = Options.new()
	options.add_option("--mode=")
	options.add_option("--loud", {&"short": "l"})
	options.add_option("--class=", {&"flag_completion": {"type": FlagType.CLASS}})
	options.add_option("--user-class=", {&"flag_completion": {"type": FlagType.USER_CLASS}})
	options.add_option("--file=", {&"flag_completion": {"type": FlagType.FILE, "dir": "res://tests/gdsh/fixtures/commands/", "ext": ["gd"]}})
	options.add_option("--dir=", {&"flag_completion": {"type": FlagType.DIR, "dir": "res://tests/gdsh/fixtures/commands/"}})
	options.show_variables()
	return options.get_options()

func _process_flag(flag:String):
	if flag.begins_with("--mode="):
		mode = _get_flag_value(flag)
	elif flag == "--loud":
		loud = true

func _execute(ctx:Context):
	ctx.append_output("%s:%s:%s:%s" % [mode, loud, ",".join(positional_args), ",".join(payload)])

func _get_completions(completion:Completion):
	var flag_options = _get_flag_type_completions(completion)
	if flag_options != null:
		return flag_options
	var options = Options.new()
	options.merge(_get_flags())
	options.add_option("route:%s:%s:%s:%s" % [mode, completion.positional_arg_index, completion.payload_arg_index, ",".join(completion.positional_args)])
	return options
