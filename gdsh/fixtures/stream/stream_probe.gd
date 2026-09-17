extends GDSh.CommandBase
## Prints one line per frame, so streamed output is observable while the command still runs.

static func get_command_name():
	return "stream_probe"

static func get_self_command_data():
	return _command_data({&"help": "Print N lines, one per frame", &"positional_count": 1})

func _execute(ctx:Context):
	var tree = Engine.get_main_loop() as SceneTree
	for i in int(positional_args[0]):
		ctx.append_output("line%d" % i)
		await tree.process_frame
	return ExitCode.OK
