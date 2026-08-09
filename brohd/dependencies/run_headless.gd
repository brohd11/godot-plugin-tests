extends SceneTree
## Clean-compile headless entry for the dependency-collector suite, exiting with a CI code.
##     godot --headless --path . --script res://tests/brohd/dependencies/run_headless.gd
##
## The scanner never loads a resource and the fixtures are written to user://, so this runs
## without an editor and without touching the project's import state.

const SUITES:PackedStringArray = [
	"res://tests/brohd/dependencies/dependencies_test.gd",
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
