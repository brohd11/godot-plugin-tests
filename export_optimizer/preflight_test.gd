extends RefCounted

const Preflight = preload("res://addons/export_optimizer/src/preflight.gd")
const VALUE = "res://tests/export_optimizer/fixtures/value.gd"
const BAD = "res://tests/export_optimizer/fixtures/invalid_struct.gd"


static func run_tests() -> Dictionary:
	var failures:Array = []
	var preflight = Preflight.new()
	preflight.prepare({VALUE: VALUE}, {})
	if not preflight.errors.is_empty() or not preflight.replacements.has(VALUE):
		failures.append("valid struct was not optimized: %s" % [preflight.errors])
	var original = FileAccess.get_file_as_string(VALUE)
	preflight.prepare({VALUE: VALUE, BAD: BAD}, {})
	if preflight.errors.is_empty() or not preflight.replacements.is_empty():
		failures.append("failed preflight retained replacements")
	if FileAccess.get_file_as_string(VALUE) != original:
		failures.append("preflight changed the source file")
	preflight.prepare({VALUE: VALUE}, {})
	if not preflight.errors.is_empty() or not preflight.replacements.has(VALUE):
		failures.append("failed batch contaminated the next export")
	preflight.clear()
	if not preflight.replacements.is_empty() or not preflight.errors.is_empty():
		failures.append("export end retained state")
	var output:Array = ["export preflight: %d failures" % failures.size()]
	output.append_array(failures)
	return {"result": failures.size(), "output": output}

