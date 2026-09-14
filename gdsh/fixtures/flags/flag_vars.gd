extends GDSh.CommandBase
## Flags bound by the default _flag_set_var (no _process_flag override).

var text_flag := "default"
var count_flag := 0
var ratio_flag := 0.5
var loud_flag := false
var dry_run_flag := false
var size_flag := Vector2i.ZERO

static func get_command_name():
	return "flagvars"

static func get_self_command_data():
	return _command_data({&"help": "Report flag vars set by the default flag binding"})

func _get_flags() -> Dictionary:
	var options = Options.new()
	options.add_option("--text=")
	options.add_option("--count=")
	options.add_option("--ratio=")
	options.add_option("--loud", {&"short": "l"})
	options.add_option("--dry-run")
	options.add_option("--size=")
	return options.get_options()

func _execute(ctx:Context):
	ctx.append_output("%s:%s:%s:%s:%s:%d,%d" % [text_flag, count_flag, ratio_flag, loud_flag, dry_run_flag, size_flag.x, size_flag.y])
