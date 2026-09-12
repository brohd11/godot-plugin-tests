extends GDSh.CommandBase
static var calls:int = 0

static func get_command_name():
	return "raw"

static func get_self_command_data():
	return _command_data({&"help": "Host raw command fixture", &"raw": true})

func execute_raw(text:String, ctx:Context) -> int:
	calls += 1
	ctx.append_output(text.strip_edges())
	ctx.append_error("raw diagnostic")
	return 7 if text.strip_edges() == "fail" else 0

func complete_raw(text:String, _completion:Completion) -> Dictionary:
	var options = Options.new()
	options.add_option("raw:" + text)
	return options.get_options()
