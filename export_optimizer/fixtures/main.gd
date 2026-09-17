extends SceneTree

const User = preload("user.gd")
const Blind = preload("blind.gd")
const References = preload("references.gd")

func _init() -> void:
	for path:String in ["test.gd", "test.gd.remap", "test.gd::Inner", "image.png"]:
		if User.path_check(path) != (path != "image.png"):
			printerr("PREDICATE_SMOKE_FAILED")
			quit(1)
			return
	var value := User.make_value()
	var struct_total := User.read_value(value)
	var expanded := User.expanded_vector(Vector2(2, 3), 2.0)
	var expected = TYPE_ARRAY if "optimized" in OS.get_cmdline_user_args() else TYPE_OBJECT
	if (User.same_file_default() != 3 or struct_total != 14 or value.amount != 7 or User.inline_struct() != 21 or User.total() != 15 or Blind.read() != 5 or typeof(User.make()) != expected
			or User.inline_total(7) != 50 or User.affine(7, 3) != 25
			or OptimizerSmokeUser.affine(7, 3) != 25 or expanded != 74.0 or User.expanded_total() != 74.0 or References.total() != 21):
		printerr("OPTIMIZER_SMOKE_FAILED")
		quit(1)
	else:
		print("OPTIMIZER_SMOKE_OK")
		quit()
