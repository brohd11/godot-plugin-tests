extends SceneTree

func _init() -> void:
	var failures = 0
	for name in ["tag_registry", "struct", "optimizer", "inline", "expression_inline", "composition", "expanded_inline", "template_inline", "struct_optimization", "struct_references"]:
		var suite = load("res://tests/gdscript_optimizer/%s_test.gd" % name)
		if suite == null or not suite.has_method("run_tests"):
			failures += 1
			continue
		var result:Dictionary = suite.run_tests()
		failures += result.result
		print("\n".join(result.output))
	quit(0 if failures == 0 else 1)
