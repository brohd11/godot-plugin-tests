## Backend availability for the syntax_plus suites' native mode.
##
## Deliberately a copy of tests/gdscript_parser/lsp_support.gd: each top-level tests folder must
## compile in isolation, so no cross-domain preload.
##
## Never reference GDScriptLSPService / GDScriptLanguageService by global class_name here: an
## undeclared identifier is a PARSE error, so a suite naming the class directly could not even load
## once the addon was removed. Everything below goes through ClassDB / load().

const SERVICE_PATH := "res://addons/addon_lib/gdscript_lsp/service.gd"


## True only when the backend can actually serve a parse: the service node is built under EditorNode,
## so outside the editor get_instance() returns null and the parser silently uses the text path.
static func available() -> bool:
	if not ClassDB.class_exists(&"GDScriptLanguageService"):
		return false
	if not ResourceLoader.exists(SERVICE_PATH):
		return false
	return load(SERVICE_PATH).get_instance() != null


## Guard against the silent plain-text fallback: ParserClass.use_ts is set only on the native path.
static func engaged(parser) -> bool:
	var root = parser.get_class_object("")
	return root != null and root.use_ts


## Standard skip line; aggregators count these so a skipped suite never reads as a pass.
static func skip_line(scope: String, reason := "LSP backend unavailable") -> String:
	return "SKIP: %s - %s" % [scope, reason]
