extends SceneTree
## Clean-compile headless entry point for the access-path test suite.
##     godot --headless --path . --script res://tests/gdscript_parser/run_headless.gd

## _initialize(), not _init(): the main loop is null during _init(), so the native backend cannot
## attach and native-mode checks would skip. See run_all_headless.gd.
func _initialize() -> void:
	_run_suite.call_deferred()


func _run_suite() -> void:
	var res: Dictionary = load("res://tests/gdscript_parser/access_path_test.gd").run_tests()
	print("\n".join(res.output))
	quit(0 if res.result == 0 else 1)
