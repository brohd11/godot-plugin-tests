extends SceneTree

func _init() -> void:
	var result = load("res://tests/export_optimizer/preflight_test.gd").run_tests()
	print("\n".join(result.output))
	quit(0 if result.result == 0 else 1)
