extends SceneTree
## Headless: python3 tests/gdsh/run_headless.py
## Editor console: `test gdsh` runs the same checks, except console input consumption (headless only).
const Suite = preload("res://tests/gdsh/runtime_suite.gd")


func _initialize():
	_run.call_deferred()


func _run():
	var res = await run_tests()
	print("\n".join(res.output))
	quit(0 if res.result == 0 else 1)


## Entry for the editor console `test` command, which awaits the frame-dependent checks.
static func run_tests() -> Dictionary:
	var suite = Suite.new()
	suite.run_sync()
	await suite.run_frames()
	return {"result": suite.failures, "output": suite.finish()}
