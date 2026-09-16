extends RefCounted

const Parser = preload("res://addons/addon_lib/gdscript_parser/gdscript_parser.gd")
const LspSupport = preload("res://tests/gdscript_parser/lsp_support.gd")
const SOURCE = "res://tests/gdscript_parser/fixtures/relative_preload.gd"
const TARGET = "res://tests/gdscript_parser/fixtures/relative_payload.gd"


static func run_tests() -> Dictionary:
	var output:Array = []
	var failures = _run(output)
	return {"result": failures, "output": output}


static func _run(output:Array) -> int:
	var failures = 0
	var modes = [false, true] if LspSupport.available() else [false]
	for native:bool in modes:
		var parser = Parser.new()
		parser.use_native_backend = native
		parser.code_edit_parser.use_native_backend = native
		parser.set_parser_cache({})
		parser.set_parser_cache_size(-1)
		parser.active_parser = parser
		parser.set_current_script(load(SOURCE))
		parser.set_source_code(FileAccess.get_file_as_string(SOURCE))
		parser.parse()
		var cases = {
			"Relative": TARGET,
			"Inner": TARGET + ".Payload",
			"Relative.make()": TARGET + ".Payload" + Parser.Keys.INS_DELIM,
			"item": TARGET + ".Payload" + Parser.Keys.INS_DELIM,
		}
		for expression:String in cases:
			var actual = parser.resolve_expression_to_type(expression, 7)
			if actual != cases[expression]:
				failures += 1
				output.append("FAIL relative preload (%s) %s: %s" % [native, expression, actual])
	output.append("relative preloads: %d failures" % failures)
	return failures
