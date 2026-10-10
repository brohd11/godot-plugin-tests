extends RefCounted

## script_tabs reparents the CodeEdit on every tab switch; reparent fires tree_exiting, which used to
## discard the service buffer and leave the native manager permanently detached. Editor-only: the
## service node needs EditorNode, so headless runs report a SKIP.

const Parser = preload("res://addons/_lib/gdscript_parser/gdscript_parser.gd")
const LspSupport = preload("res://tests/gdscript_parser/lsp_support.gd")
const SOURCE = "res://tests/gdscript_parser/fixtures/relative_preload.gd"


static func run_tests() -> Dictionary:
	var output:Array = []
	var failures = _run(output)
	return {"result": failures, "output": output}


static func _run(output:Array) -> int:
	if not LspSupport.available():
		output.append(LspSupport.skip_line("lsp reparent"))
		return 0
	var service = load(LspSupport.SERVICE_PATH).get_instance()
	if not service.has_method(&"_check_editor_left"):
		output.append("FAIL lsp reparent - live service predates the fix; reload the editor")
		return 1
	var root:Node = (Engine.get_main_loop() as SceneTree).root
	var failures := 0
	failures += _check(output, "reparent keeps buffer", _reparent_keeps_buffer(service, root))
	failures += _check(output, "freed edit discards buffer", _freed_edit_discards(service, root))
	failures += _check(output, "parse reattaches dropped buffer", _parse_reattaches(service, root))
	output.append("lsp reparent: %d failures" % failures)
	return failures


static func _check(output:Array, name:String, ok:bool) -> int:
	output.append("%s %s" % ["PASS" if ok else "FAIL", name])
	return 0 if ok else 1


static func _new_edit(root:Node) -> CodeEdit:
	var edit := CodeEdit.new()
	edit.text = FileAccess.get_file_as_string(SOURCE)
	root.add_child(edit)
	return edit


static func _reparent_keeps_buffer(service, root:Node) -> bool:
	var holder := Node.new()
	root.add_child(holder)
	var edit := _new_edit(root)
	var key:String = service.acquire(edit, SOURCE)
	edit.reparent(holder)
	service._check_editor_left(key) # the deferred check, run synchronously
	var ok:bool = service._buffers.has(key) and is_instance_valid(service.get_document(key))
	service.release(key)
	holder.free()
	return ok


static func _freed_edit_discards(service, root:Node) -> bool:
	var edit := _new_edit(root)
	var key:String = service.acquire(edit, SOURCE)
	edit.free()
	service._check_editor_left(key)
	return not service._buffers.has(key)


static func _parse_reattaches(service, root:Node) -> bool:
	var edit := _new_edit(root)
	var parser = Parser.new()
	parser.set_use_native_backend(true)
	parser.active_parser = parser
	parser.set_current_script(load(SOURCE))
	parser.set_code_edit(edit)
	parser.parse()
	var manager = parser.code_edit_parser.native_manager
	var ok:bool = is_instance_valid(manager) and manager.is_attached()
	if ok:
		service._discard(manager._key) # what a tree_exiting discard used to leave behind
		ok = not manager.is_attached()
		parser.parse()
		ok = ok and manager.is_attached() and LspSupport.engaged(parser)
	if is_instance_valid(manager):
		manager.detach()
	edit.free()
	return ok
