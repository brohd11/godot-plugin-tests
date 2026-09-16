extends RefCounted

#! struct
class Point:
	var x: float
	var y: float
	func _init(a: float, b: float) -> void:
		x = a
		y = b

#! struct
class Motion:
	var position: Vector2
	var velocity: Vector2
	func _init(p: Vector2, v: Vector2) -> void:
		position = p
		velocity = v

static func allocation(count: int) -> float:
	var total := 0.0
	for i in count:
		var point := Point.new(float(i % 128), 2.0)
		point.x += 0.5
		total += point.x + point.y
	return total

static func arithmetic(count: int) -> float:
	return arithmetic_loop(Point.new(3.0, 7.0), count)

static func arithmetic_loop(point: Point, count: int) -> float:
	var total := 0.0
	for i in count:
		total += point.x * 1.01 + point.y * 1.02
	return total

static func consume(value: float) -> float:
	return value * 1.25 + 1.0

static func script_calls(count: int) -> float:
	return script_loop(Point.new(3.0, 7.0), count)

static func script_loop(point: Point, count: int) -> float:
	var total := 0.0
	for i in count:
		total += consume(point.x)
	return total

static func engine_calls(count: int) -> float:
	return engine_loop(Motion.new(Vector2(2, 3), Vector2.ONE), count)

static func engine_loop(motion: Motion, count: int) -> float:
	var total := 0.0
	var direction := Vector2(1, 2)
	for i in count:
		total += direction.dot(motion.position)
	return total

static func vectors(count: int) -> float:
	var total := 0.0
	for i in count:
		var motion := Motion.new(Vector2(float(i % 128), 2.0), Vector2(0.5, 1.0))
		motion.position += motion.velocity
		total += motion.position.length_squared()
	return total

#! inline
static func affine(value: float) -> float:
	return value * 1.25 + 1.0

static func inline_calls(count: int) -> float:
	return inline_loop(Point.new(3.0, 7.0), count)

static func inline_loop(point: Point, count: int) -> float:
	var total := 0.0
	for i in count:
		var increment: float = affine(point.x)
		total += increment
	return total


class Payload:
	var value:float = 3.0

#! struct
class Reference:
	var payload:Payload
	func _init(p:Payload) -> void:
		payload = p

static func reference_allocation(count:int) -> float:
	var payload := Payload.new()
	var total := 0.0
	for i in count:
		var record := Reference.new(payload)
		total += record.payload.value
	return total

static func reference_reads(count:int) -> float:
	return reference_loop(Reference.new(Payload.new()), count)

static func reference_loop(record:Reference, count:int) -> float:
	var total := 0.0
	for i in count:
		var payload = record.payload
		total += payload.value
	return total
