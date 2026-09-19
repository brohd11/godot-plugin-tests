extends RefCounted

var count:int = 42
var label = "cache policy"

func local_value():
	var item = 42
	return item

func recursive_value():
	return recursive_value()
