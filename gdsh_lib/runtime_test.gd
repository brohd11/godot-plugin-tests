extends SceneTree
## Headless (isolated): python3 tests/gdsh_lib/run_headless.py
## Editor console: `test gdsh_lib` runs the same checks.
const Suite = preload("res://tests/gdsh_lib/runtime_suite.gd")


func _initialize():
	_run.call_deferred()


func _run():
	var res = await run_tests()
	print("\n".join(res.output))
	quit(0 if res.result == 0 else 1)


static func run_tests() -> Dictionary:
	var suite = Suite.new()
	suite.run_sync()
	await suite.run_frames()
	return {"result": suite.failures, "output": suite.finish()}
