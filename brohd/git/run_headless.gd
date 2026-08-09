extends SceneTree
## Clean-compile headless entry for the git suites, exiting with a CI code.
##     godot --headless --path . --script res://tests/brohd/git/run_headless.gd
##
## Both suites are pure — parse_status / parse_patch over captured fixtures, and a line diff that
## never had anything to do with git — so nothing here spawns git.

const SUITES:PackedStringArray = [
	"res://tests/brohd/git/git_util_test.gd",
	"res://tests/brohd/git/git_diff_test.gd",
]

func _init() -> void:
	var success = true
	var output:Array[String] = []

	# every suite runs even after one fails: a red suite is a reason to see the rest, not to hide it
	for path in SUITES:
		var res:Dictionary = load(path).run_tests()
		success = success and res.result == 0
		output.append_array(res.output)

	print("\n".join(output))
	quit(0 if success else 1)
