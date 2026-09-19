extends RefCounted

const Preflight = preload("res://addons/export_optimizer/src/preflight.gd")
const VALUE = "res://tests/export_optimizer/fixtures/value.gd"
const BAD = "res://tests/export_optimizer/fixtures/invalid_struct.gd"
const INLINE = "res://tests/export_optimizer/fixtures/inline.gd"


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
	preflight.prepare({INLINE: INLINE}, {})
	if not preflight.replacements.is_empty():
		failures.append("default pass selection unexpectedly enabled inline")
	var passes := [Preflight.Optimizer.StructPass, Preflight.Optimizer.InlinePass]
	preflight.prepare({INLINE: INLINE, VALUE: VALUE}, {}, passes)
	if (not preflight.errors.is_empty() or preflight.replacements.size() != 2
			or preflight.stats.get("inline_calls", 0) != 2):
		failures.append("combined passes did not aggregate replacements and inline statistics")
	preflight.prepare({INLINE: INLINE, VALUE: VALUE, BAD: BAD}, {}, passes)
	if preflight.errors.is_empty() or not preflight.replacements.is_empty():
		failures.append("failed combined preflight retained replacements")
	for aggressive:bool in [false, true]:
		preflight.prepare({INLINE: INLINE}, {}, [Preflight.Optimizer.InlinePass], {"aggressive": aggressive})
		if not preflight.errors.is_empty() or preflight.stats.get("inline_calls", 0) != (5 if aggressive else 2):
			failures.append("aggressive policy was not forwarded: " + str(preflight.stats))
	for mode:String in ["tagged", "auto", "off"]:
		preflight.prepare({VALUE: VALUE}, {}, passes, {"struct_mode": mode, "inline_mode": "off"})
		if not preflight.errors.is_empty() or preflight.replacements.is_empty() != (mode == "off"):
			failures.append("struct mode not forwarded: " + mode)
	preflight.prepare({VALUE: VALUE}, {}, passes, {"struct_mode": "unknown"})
	if preflight.errors.is_empty() or not preflight.replacements.is_empty():
		failures.append("invalid mode was accepted")
	preflight.clear()
	if not preflight.replacements.is_empty() or not preflight.errors.is_empty() or not preflight.stats.is_empty():
		failures.append("export end retained state")
	var output:Array = ["export preflight: %d failures" % failures.size()]
	output.append_array(failures)
	return {"result": failures.size(), "output": output}
