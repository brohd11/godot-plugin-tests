extends SceneTree
## Clean-compile headless entry for the code_completions suites, exiting with a CI code.
##     godot --headless --path . --script res://tests/code_completions/run_headless.gd

const SUITES:PackedStringArray = [
	"res://tests/code_completions/alias_completion_test.gd",
]

func _init() -> void:
	var success = true
	var output:Array[String] = []

	for path in SUITES:
		var res:Dictionary = load(path).run_tests()
		success = success and res.result == 0
		output.append_array(res.output)

	print("\n".join(output))
	quit(0 if success else 1)
