extends RefCounted

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


static func make_value() -> Value:
	return Value.new(5)


static func total() -> int:
	var point := make()
	var value := make_value()
	var pair:Pair = Pair.new(1, 2)
	var values:Array[OptimizerSmokePoint] = [point]
	var get_x = func(p:OptimizerSmokePoint) -> int: return p.x
	return get_x.call(values[0]) + point.y + value.amount + pair.left + pair.right

