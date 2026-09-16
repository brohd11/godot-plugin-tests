extends RefCounted

class Payload:
	var value:int = 9

#! struct
class Record:
	var payload:Payload
	var items:Array = []
	func _init(p:Payload) -> void:
		payload = p

static func total() -> int:
	var payload := Payload.new()
	var record := Record.new(payload)
	record.items.append(3)
	return record.payload.value + record.items[0] + read(Record.new(payload))

static func read(record:Record) -> int:
	var payload = record.payload
	return payload.value
