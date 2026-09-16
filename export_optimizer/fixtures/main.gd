extends SceneTree

const User = preload("user.gd")
const Blind = preload("blind.gd")

func _init() -> void:
	var expected = TYPE_ARRAY if "optimized" in OS.get_cmdline_user_args() else TYPE_OBJECT
	if User.total() != 15 or Blind.read() != 5 or typeof(User.make()) != expected:
		printerr("OPTIMIZER_SMOKE_FAILED")
		quit(1)
	else:
		print("OPTIMIZER_SMOKE_OK")
		quit()

