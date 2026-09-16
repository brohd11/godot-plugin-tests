## Backend availability for the parser suites' native mode.
##
## Never reference GDScriptLSPService / GDScriptLanguageService by global class_name here: an
## undeclared identifier is a PARSE error, so a suite that named the class directly could not even
## load once the addon was removed (that is what broke inline_lambda_test.gd). Everything below goes
## through ClassDB / load() so a missing addon is a runtime false, not a dead file.

const SERVICE_PATH := "res://addons/addon_lib/gdscript_lsp/service.gd"


## True only when the backend can actually serve a parse. The class existing is not enough: the
## service node is built under EditorNode, so outside the editor get_instance() returns null and
## code_edit_parser.gd silently falls back to the text parser.
static func available() -> bool:
	if not ClassDB.class_exists(&"GDScriptLanguageService"):
		return false
	if not ResourceLoader.exists(SERVICE_PATH):
		return false
	return load(SERVICE_PATH).get_instance() != null


## The service without the editor-owned node: usable headless for structural reads.
## Returns null when the extension is not registered.
static func new_service() -> Object:
	if not ClassDB.class_exists(&"GDScriptLanguageService"):
		return null
	return ClassDB.instantiate(&"GDScriptLanguageService")


## Guard against the silent plain-text fallback: ParserClass.use_ts is set only on the native parse
## path (code_edit_parser.gd), so this is what proves the mode under test actually ran.
static func engaged(parser) -> bool:
	var root = parser.get_class_object("")
	return root != null and root.use_ts


## Standard skip line; run_all_tests.gd counts these so a skipped suite never reads as a pass.
static func skip_line(scope: String, reason := "LSP backend unavailable") -> String:
	return "SKIP: %s - %s" % [scope, reason]
