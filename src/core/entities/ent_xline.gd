class_name EntXline
extends CadEntity
## 构造线 / 射线。对应 DXF 的 XLINE（双向无限）与 RAY（单向无限）。
##
## 制图中用来做辅助线：过一点沿某方向无限延伸，本身不打印
## （在标准图层/打印样式里通常设为不打印，出图时排除）。
##
## 实现取舍：几何上真正的无限直线无法用 GeoCurve 表达，
## 这里用一条**足够长**的有向线段近似（默认 ±500 米），
## 既能让求交与捕捉正常工作，又避免数值溢出。

## 长度上限 (mm)。500 米对任何房屋建筑都足够"无限"。
const HALF_EXTENT := 500000.0

var point: Vector2 = Vector2.ZERO
## 方向（会被归一化）
var direction: Vector2 = Vector2.RIGHT
## true = 单向射线，false = 双向构造线
var ray: bool = false


static func make(p: Vector2, dir: Vector2, is_ray := false) -> EntXline:
	var e := EntXline.new()
	e.type = CadEntity.Type.RAY if is_ray else CadEntity.Type.XLINE
	e.point = p
	e.direction = dir.normalized() if dir.length() > Tol.MIN_LEN else Vector2.RIGHT
	e.ray = is_ray
	return e


func type_name() -> String:
	return "射线" if ray else "构造线"


func get_curves() -> Array[GeoCurve]:
	if ray:
		return [GeoSeg.make(point, point + direction * HALF_EXTENT)]
	return [GeoSeg.make(point - direction * HALF_EXTENT, point + direction * HALF_EXTENT)]


func get_grips() -> PackedVector2Array:
	return PackedVector2Array([point, point + direction * 1000.0])


func move_grip(index: int, pos: Vector2) -> void:
	if index == 0:
		point = pos
	elif index == 1:
		var d := pos - point
		if d.length() > Tol.MIN_LEN:
			direction = d.normalized()
	invalidate_bbox()


func get_bbox() -> Rect2:
	# 构造线视为铺满整个图面，不参与视口剔除
	var c := get_curves()[0]
	return c.bbox()


func transform_by(xf: Transform2D) -> void:
	point = xf * point
	var d := xf.x
	if d.length() > Tol.MIN_LEN:
		direction = d.normalized()
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make(point, direction, ray)
	_copy_base_to(e)
	return e


func explode() -> Array[CadEntity]:
	return []


func to_dict() -> Dictionary:
	var d := super.to_dict()
	_put_v2(d, "point", point)
	_put_v2(d, "direction", direction)
	d["ray"] = ray
	return d


static func from_dict(d: Dictionary) -> EntXline:
	var e := EntXline.new()
	e.type = CadEntity.Type.RAY if bool(d.get("ray", false)) else CadEntity.Type.XLINE
	e.read_base_fields(d)
	e.point = _v2(d, "point")
	var dir := _v2(d, "direction")
	e.direction = dir.normalized() if dir.length() > Tol.MIN_LEN else Vector2.RIGHT
	e.ray = bool(d.get("ray", false))
	return e
