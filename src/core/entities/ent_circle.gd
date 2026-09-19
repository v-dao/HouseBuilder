class_name EntCircle
extends CadEntity
## 圆。对应 DXF 的 CIRCLE（圆心组码 10，半径组码 40）。
## 渲染与几何运算内部统一用 GeoArc 表达（sweep = TAU）。

var center: Vector2 = Vector2.ZERO
var radius: float = 1.0


static func make(c: Vector2, r: float) -> EntCircle:
	var e := EntCircle.new()
	e.type = CadEntity.Type.CIRCLE
	e.center = c
	e.radius = maxf(r, Tol.MIN_RADIUS)
	return e


func type_name() -> String:
	return "圆"


func get_curves() -> Array[GeoCurve]:
	return [GeoArc.make_circle(center, radius)]


func get_grips() -> PackedVector2Array:
	# 圆心 + 四个象限点（AutoCAD 圆的标准夹点）
	return PackedVector2Array([
		center,
		center + Vector2(radius, 0),
		center + Vector2(0, radius),
		center + Vector2(-radius, 0),
		center + Vector2(0, -radius),
	])


func move_grip(index: int, pos: Vector2) -> void:
	if index == 0:
		center = pos
	else:
		# 拖动象限点改半径
		radius = maxf(center.distance_to(pos), Tol.MIN_RADIUS)
	invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	center = xf * center
	# 只支持相似变换：取 x 轴长度作为缩放比例
	radius = maxf(radius * xf.x.length(), Tol.MIN_RADIUS)
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make(center, radius)
	_copy_base_to(e)
	return e


func explode() -> Array[CadEntity]:
	return []


func circumference() -> float:
	return TAU * radius


func area() -> float:
	return PI * radius * radius


func to_dict() -> Dictionary:
	var d := super.to_dict()
	_put_v2(d, "center", center)
	d["radius"] = snappedf(radius, 0.000001)
	return d


static func from_dict(d: Dictionary) -> EntCircle:
	var e := EntCircle.new()
	e.type = CadEntity.Type.CIRCLE
	e.read_base_fields(d)
	e.center = _v2(d, "center")
	e.radius = maxf(float(d.get("radius", 1.0)), Tol.MIN_RADIUS)
	return e
