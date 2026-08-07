extends SceneTree
## Clean-compile headless entry point for the inference test suite.
##     Godot --headless --path . --script res://tests/gdscript_parser/run_inference_headless.gd
## Exits non-zero if any case fails. Use inference_test.gd's probe_all() to author new cases.

func _init() -> void:
	var res: Dictionary = load("res://tests/gdscript_parser/inference_test.gd").run_tests()
	print("\n".join(res.output))
	quit(0 if res.result == 0 else 1)
