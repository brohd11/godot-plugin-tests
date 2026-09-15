@tool
extends EditorScript

## Tests for arr_struct.gd's static helpers.
##
## The completions need a live parser and caret, so this pins the pure rules they rest on: where the
## class tag is looked up, which enum members count as slots and their types by index, how tags are
## read, and the array-literal checks behind the call-site hint. `|` in a sample marks the caret.

const ArrStruct = preload("res://addons/code_completions/src/completions/arr_struct.gd")
const ParserKeys = ArrStruct.ParserKeys

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_class_tag_path()
	_test_unnamed_enum_members()
	_test_is_array_type()
	_test_parse_arg_types()
	_test_parse_constructor()
	_test_member_types_by_index()
	_test_get_option_text()
	_test_is_direct_array_arg()
	_test_array_element_index()
	_test_build_struct_hint()

	var output:Array[String] = []
	output.append("arr_struct: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)

	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	var res = run_tests()
	print("\n".join(res.output))


static func _test_class_tag_path() -> void:
	var inner = ArrStruct.class_tag_path("res://a.gd.S")
	_check(inner == "res://a.gd.S::S", "class_tag_path inner -> %s" % inner)
	var nested = ArrStruct.class_tag_path("res://a.gd.Outer.S")
	_check(nested == "res://a.gd.Outer.S::S", "class_tag_path nested -> %s" % nested)
	var main = ArrStruct.class_tag_path("res://a.gd")
	_check(main == "", "class_tag_path main script has no class line -> %s" % main)


static func _test_unnamed_enum_members() -> void:
	var basic = ArrStruct.unnamed_enum_members(["enum {A, B}"])
	_check(basic == {"A": 0, "B": 1}, "unnamed enum -> %s" % [basic])
	var named = ArrStruct.unnamed_enum_members(["enum Named {X, Y}"])
	_check(named.is_empty(), "named enum ignored -> %s" % [named])
	var valued = ArrStruct.unnamed_enum_members(["enum {A = 3, B}"])
	_check(valued == {"A": 3, "B": 4}, "explicit values carry on -> %s" % [valued])
	var mixed = ArrStruct.unnamed_enum_members(["enum Named {X}", "enum {A}", "enum {B, C,}"])
	_check(mixed.keys() == ["A", "B", "C"], "mixed enums keep declaration order -> %s" % [mixed])
	var multiline = ArrStruct.unnamed_enum_members(["enum {\n\tA,\n\tB\n}"])
	_check(multiline == {"A": 0, "B": 1}, "joined multiline enum -> %s" % [multiline])
	var not_enum = ArrStruct.unnamed_enum_members(["enum_like()"])
	_check(not_enum.is_empty(), "non enum text -> %s" % [not_enum])


static func _test_is_array_type() -> void:
	_check(ArrStruct.is_array_type("Array"), "Array")
	_check(ArrStruct.is_array_type("Array[int]"), "typed Array")
	_check(ArrStruct.is_array_type("Array" + ParserKeys.INS_DELIM), "Array instance")
	_check(not ArrStruct.is_array_type("Dictionary"), "Dictionary is not an array")
	_check(not ArrStruct.is_array_type("PackedStringArray"), "packed arrays are not structs")
	_check(not ArrStruct.is_array_type(""), "empty type")


static func _test_parse_arg_types() -> void:
	var empty = ArrStruct.parse_arg_types(" ")
	_check(empty.is_empty(), "bare class tag has no args -> %s" % [empty])
	var one = ArrStruct.parse_arg_types("data:MyStruct")
	_check(one == {"data": "MyStruct"}, "one arg -> %s" % [one])
	var several = ArrStruct.parse_arg_types("a:S  b:T")
	_check(several == {"a": "S", "b": "T"}, "several args -> %s" % [several])
	var dotted = ArrStruct.parse_arg_types("a:Outer.S")
	_check(dotted == {"a": "Outer.S"}, "dotted type -> %s" % [dotted])
	var spaced = ArrStruct.parse_arg_types("a: S b :T")
	_check(spaced == {"a": "S", "b": "T"}, "spaces around ':' -> %s" % [spaced])


static func _test_parse_constructor() -> void:
	_check(ArrStruct.parse_constructor(" ") == "", "bare tag has no constructor")
	_check(ArrStruct.parse_constructor("create") == "create", "named constructor")
	_check(ArrStruct.parse_constructor("data: S") == "", "arg type is not a constructor")
	_check(ArrStruct.parse_constructor("a:S make") == "make", "constructor after args")


static func _test_member_types_by_index() -> void:
	var arg_types = ["int", "String"]
	var basic = ArrStruct.member_types_by_index({"A": 0, "B": 1}, arg_types)
	_check(basic == {"A": "int", "B": "String"}, "types by slot index -> %s" % [basic])
	var valued = ArrStruct.member_types_by_index({"B": 1}, arg_types)
	_check(valued == {"B": "String"}, "value, not order, picks the arg -> %s" % [valued])
	var out_of_range = ArrStruct.member_types_by_index({"C": 5}, arg_types)
	_check(out_of_range == {"C": ""}, "out of range is empty -> %s" % [out_of_range])
	var expression = ArrStruct.member_types_by_index({"D": "1 << 2"}, arg_types)
	_check(expression == {"D": ""}, "non int value is empty -> %s" % [expression])


static func _test_get_option_text() -> void:
	var prefixed = ArrStruct.get_option_text("MyStruct", "MEMBER")
	_check(prefixed == "get(MyStruct.MEMBER)", "prefixed option -> %s" % prefixed)
	var bare = ArrStruct.get_option_text("", "MEMBER")
	_check(bare == "get(MEMBER)", "bare option inside the struct -> %s" % bare)


static func _test_is_direct_array_arg() -> void:
	_check(_direct_array("f([|])"), "array as the first arg")
	_check(_direct_array("f(x, [|])"), "array after a comma")
	_check(_direct_array("f(x, [a], [ |])"), "earlier closed array and inner space")
	_check(not _direct_array("f([[|]])"), "nested array is not the arg")
	_check(not _direct_array("f([a, [|]])"), "array inside the arg array is not the arg")


static func _test_array_element_index() -> void:
	_check(_element_index("f([|])") == 0, "first element")
	_check(_element_index("f([1, |])") == 1, "after a comma")
	_check(_element_index("f([[1, 2], |])") == 1, "nested array commas skipped")
	_check(_element_index("f([\"a,b\", |])") == 1, "string commas skipped")
	_check(_element_index("f([g(1, 2), 3, |])") == 2, "call commas skipped")


static func _test_build_struct_hint() -> void:
	var mark = char(ArrStruct.HINT_MARK)
	var members = {"A": 0, "B": 1}
	var types = {"A": "int"}
	var hint = ArrStruct.build_struct_hint(members, types, 1)
	_check(hint == "A: int, %sB: Variant%s" % [mark, mark], "marks the slot, Variant fallback -> %s" % hint.replace(mark, "|"))
	var none = ArrStruct.build_struct_hint(members, types, 5)
	_check(not none.contains(mark), "no slot past the end -> %s" % none.replace(mark, "|"))


# innermost open of `bracket` around the caret, as CaretContext._check_brackets finds it
static func _innermost(string_map, text:String, caret:int, bracket:String) -> int:
	var best:int = -1
	for open:int in string_map.bracket_map:
		var close:int = string_map.bracket_map[open]
		if open < close and text[open] == bracket and open < caret and close >= caret:
			best = max(best, open)
	return best

static func _direct_array(marked:String) -> bool:
	var caret:int = marked.find("|")
	var text:String = marked.replace("|", "")
	var string_map = ArrStruct.UString.get_string_map(text)
	var paren:int = _innermost(string_map, text, caret, "(")
	var square:int = _innermost(string_map, text, caret, "[")
	return ArrStruct.is_direct_array_arg(string_map.bracket_map, paren, square, text)

static func _element_index(marked:String) -> int:
	var caret:int = marked.find("|")
	var text:String = marked.replace("|", "")
	var string_map = ArrStruct.UString.get_string_map(text)
	var square:int = _innermost(string_map, text, caret, "[")
	return ArrStruct.array_element_index(text, string_map.bracket_map, string_map.string_mask, square, caret)


static func _check(condition:bool, message:String) -> void:
	if condition:
		_passed += 1
	else:
		_failures.append(message)
