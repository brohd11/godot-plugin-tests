extends GDSh.CommandBase


static func get_command_name() -> String:
	return "echo"


static func get_self_command_data() -> Dictionary:
	return _command_data({"positional_count": "min:0"})


func _get_target_positional_count() -> int:
	return positional_args.size()


func _execute(ctx:Context) -> void:
	ctx.append_output("layered:" + " ".join(positional_args))
