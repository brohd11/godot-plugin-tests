class_name OptimizerSmokeUser extends RefCounted

const Value = preload("value.gd")

#! struct
class Pair:
	var left:int
	var right:int
	func _init(a:int, b:int) -> void:
		left = a
		right = b


static func make() -> OptimizerSmokePoint:
	return OptimizerSmokePoint.new(3, 4)


#! inline
static func affine(value:int, scale:int) -> int:
	return value * scale + value - 3


static func inline_total(value:int) -> int:
	return 2 * affine(value, 3)


static func make_value() -> Value:
	return Value.new(5)


static func total() -> int:
	var point := make()
	var value := make_value()
	var pair:Pair = Pair.new(1, 2)
	var values:Array[OptimizerSmokePoint] = [point]
	var get_x = func(p:OptimizerSmokePoint) -> int: return p.x
	return get_x.call(values[0]) + point.y + value.amount + pair.left + pair.right

#! inline
static func expanded_vector(value:Vector2, scale:float) -> float:
	var scaled := value * scale
	scaled += Vector2.ONE
	return scaled.length_squared()

static func expanded_total() -> float:
	return expanded_vector(Vector2(2, 3), 2.0)

#! inline
static func read_value(value:Value, amount:int = 2) -> int:
	value.amount += amount
	return value.amount + value.amount
static func inline_struct() -> int:
	var value := make_value()
	var total := read_value(value)
	return total + value.amount

const DEFAULT_STEP = 2
#! inline
static func step(value:int = DEFAULT_STEP) -> int:
	return value + 1
static func same_file_default() -> int:
	return step()
