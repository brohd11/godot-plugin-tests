extends GDSh.CommandBase
## Awaits frames before finishing, so the engine must wait for it.

var fail_flag = false

static func get_command_name():
	return "wait_frames"

static func get_self_command_data():
	return _command_data({&"help": "Wait N frames, then echo a label", &"positional_count": "min:1,max:2"})

func _get_flags() -> Dictionary:
	var options = Options.new()
	options.add_option("--fail")
	return options.get_options()

func _execute(ctx:Context):
	var tree = Engine.get_main_loop() as SceneTree
	for i in int(positional_args[0]):
		await tree.process_frame
	ctx.append_output("waited:" + positional_args[-1])
	return ExitCode.FAIL if fail_flag else ExitCode.OK
