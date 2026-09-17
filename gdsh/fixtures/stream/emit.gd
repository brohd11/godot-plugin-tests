extends GDSh.CommandBase
## Writes verbatim, including a trailing partial line, so streaming can be checked without
## append_output's normalization.

static func get_command_name():
	return "emit"

static func get_self_command_data():
	return _command_data({&"help": "Write 'a' then 'b' verbatim, as two chunks"})

func _execute(ctx:Context):
	ctx.write_output("a")
	ctx.write_output("b\n")
	return ExitCode.OK
