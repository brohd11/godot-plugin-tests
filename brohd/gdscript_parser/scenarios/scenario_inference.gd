@tool
extends RefCounted





## Type-inference scenarios: a renamed, deduped reproduction of test_comp.gd::test_infer_dict.
## Every local in infer_cases() has a unique, self-explanatory name that the runner
## (inference_test.gd) uses as the assertion key. Covers iteration typing, index typing,
## await->signal-arg, Callable.call() chains, cross-func callable/signal chains, constructor
## instances, subscript-new, user-type dict key/value, packed-array element, preload const, `as`
## cast, instance-vs-type, and a member-shadowing local.

@warning_ignore_start("unassigned_variable", "unused_variable", "standalone_expression", "unused_parameter", "unreachable_code", "confusable_local_declaration", "static_called_on_instance", "redundant_await")

signal local_signal(some_arg: int)

var typed_dict: Dictionary[String, int] = {}


func infer_cases() -> void:
	# explicit type on the declaration wins over the inferred RHS
	var explicit_int: int = InfSupport.INT_2

	# iteration typing: key type of a typed Dictionary, and typed values() element
	for dict_key in typed_dict:
		pass
	for dict_value in typed_dict.values():
		pass

	# builtin value + index typing
	var color_val = Color.ALICE_BLUE
	var chan_by_str = color_val["r"]
	var chan_by_idx = color_val[0]
	var html_str = color_val.to_html()
	var first_char = html_str[0]

	# lambda literal -> Callable
	var lambda_ref = func(): return

	# await a signal -> its single arg type; and the same via a Signal-valued local
	var awaited_signal_arg = await local_signal
	var signal_ref = local_signal
	var awaited_ref = await signal_ref

	# builtin function referenced as a value -> Callable; .call() -> its return type
	var builtin_callable = char
	var builtin_ret = builtin_callable.call()

	# Callable method chain terminating in a bool
	var callable_chain_bool = some_func.bind().bind().is_null()

	# cross-func chain: get_call() -> Callable, .call() -> Signal, await -> arg type (String)
	var returned_callable = get_call()
	var called_signal = returned_callable.call()
	var awaited_return = await called_signal

	# cross-func chain 2: -> Callable -> Signal(bool); plus Signal.get_connections() typing
	var returned_callable2 = get_call2()
	var called_signal2 = returned_callable2.call()
	var awaited_bool = await called_signal2
	var sig_connections = called_signal2.get_connections()
	var typed_conns: Array[String] = sig_connections

	# constructor instance + instance/static method returns + subscript-new
	var made_obj = InfSupport.new()
	var obj_string = made_obj.get_string()
	var static_string = InfSupport.static_get_string()
	var subscript_new = InfSupport["new"].call()
	var subscript_string = subscript_new.get_string()

	# a func returning a Signal (untyped), then await it
	var made_signal = made_obj.get_signal()
	var awaited_made = await made_signal

	# engine-typed local: Variant getter, Callable getter, its .call() return, awaited builtin signal
	var line: LineEdit
	var got_variant = line.get("text")
	var menu_callable = line.get_menu
	var menu = menu_callable.call()
	var awaited_text = await line.text_changed

	# user-type dictionary key/value typing
	var typed_map: Dictionary[InfEnum, InfEnum.Nested] = {}
	for map_key in typed_map:
		var map_val = typed_map.get(map_key)
		pass

	# packed array element typing
	var packed = PackedByteArray()
	for byte in packed:
		pass

	# preload(...).CONST
	var preload_const = preload("res://tests/brohd/gdscript_parser/fixtures/inf_enum.gd").MY_COLOR

	# `as` cast
	var cast_obj = Object.new() as InfEnum

	# nested static enum-returning func as a Callable, its .call() return, and a direct call
	var nested_callable = InfSupport.Nested.node_test
	var nested_call_ret = nested_callable.call()
	var nested_direct = InfSupport.Nested.node_test(Node.PROCESS_MODE_ALWAYS)

	# instance value vs the bare type
	var node_ins = Node.new()
	var node_static = Node

	# member-shadowing: a local named after a script function. Before its declaration the name is the
	# func (Callable); from the local's line onward it is the local (String).
	var pre_shadow_callable = shadowed_func
	var shadowed_func = ""
	var post_shadow = shadowed_func

func some_func() -> void:
	pass


# returns a builtin Signal (LineEdit.text_changed(new_text: String))
func funk_test():
	var code: LineEdit
	return code.text_changed


# returns funk_test as a value -> Callable
func get_call():
	return funk_test


# returns another_sig as a value -> Callable
func get_call2():
	return another_sig


# returns a Signal carrying a bool (InfSupport.sig_bool(flag: bool))
func another_sig():
	var s = InfSupport.new()
	return s.sig_bool





# Terminal local whose last body line is immediately followed by the next func declaration (NO blank
# line between). That makes `direct_terminal` the function's final func_lines entry - the end-of-func
# case that the map/scope fix must handle. `direct_terminal = seed_local` also forces the terminal
# var to resolve through in-scope locals. Keep `func _after_terminal` glued directly beneath it.
func terminal_before_func():
	var seed_local := Color.AQUA
	var direct_terminal = seed_local
func _after_terminal() -> void:
	pass


func shadowed_func() -> void:
	pass
