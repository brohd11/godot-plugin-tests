extends SceneTree
## Clean-compile headless entry that runs ALL four gdscript-parser suites and exits with a CI code.
##     Godot --headless --path . --script res://tests/brohd/gdscript_parser/run_all_headless.gd
##
## Delegates to the shared aggregator (run_all_tests.gd) so the suite list lives in one place; that
## EditorScript's `static` funcs load and run fine under bare --headless (verified).

func _init() -> void:
	var res: Dictionary = load("res://tests/brohd/gdscript_parser/run_all_tests.gd").run_tests()
	print("\n".join(res.output))
	quit(0 if res.result == 0 else 1)
