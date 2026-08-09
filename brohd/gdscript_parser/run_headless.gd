extends SceneTree
## Clean-compile headless entry point for the access-path test suite.
##     godot --headless --path . --script res://tests/brohd/gdscript_parser/run_headless.gd

func _init() -> void:
	var res: Dictionary = load("res://tests/brohd/gdscript_parser/access_path_test.gd").run_tests()
	print("\n".join(res.output))
	quit(0 if res.result == 0 else 1)
