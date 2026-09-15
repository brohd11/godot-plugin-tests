extends RefCounted
## Manual check for arr_struct completion: request completions at each `.`, `get(`, `(` or `[` below.

#! arr_struct create
class MyStruct:
	enum {MEMBER, MEMBER2}

	static func create(_member:int, _member2:String) -> Array:
		return [_member, _member2]

	static func inside() -> int:
		var own = create(1, "a")
		return own[MEMBER] # bare members inside the struct

class Untagged:
	enum {NOPE}

	static func create() -> Array:
		return [0]


static func check() -> Array:
	var s = MyStruct.create(1, "a")
	var from_member = s.get(MyStruct.MEMBER) # `s.` -> get(MyStruct.MEMBER), int icon from create's args
	var from_get = s.get(MyStruct.MEMBER2) # `s.get(` -> MyStruct.MEMBER2, String icon
	var from_index = s[MyStruct.MEMBER] # needs text typed before the popup opens
	var from_call = MyStruct.create(1, "a")[MyStruct.MEMBER2]
	var untagged = Untagged.create()[0] # no completions expected
	var dict = {"key": 1}
	var from_dict = dict["key"] # dict_key territory, unaffected
	return [from_member, from_get, from_index, from_call, untagged, from_dict]


#! arr_struct data:MyStruct
static func send_struct(data:Array) -> int:
	return data.get(MyStruct.MEMBER) # `data.` and `data.get(` work only in this func

static func calls() -> void:
	send_struct(MyStruct.create(1, "a")) # `send_struct(` -> MyStruct.create( amongst the natives
	send_struct([1, "a"]) # `send_struct([1, ` -> hint MEMBER: int, _MEMBER2: String_
	print(Untagged.create()) # untagged receiver, unchanged
