class_name EntEllipse
extends CadEntity
## 椭圆 / 椭圆弧。对应 DXF 的 ELLIPSE。
## DXF 用「中心 + 长轴端点 + 短长轴比」表达，本类内部存长短半轴与旋转角。

var center: Vector2 = Vector2.ZERO
var radius_a: float = 1.0
var radius_b: float = 1.0
## 旋转角 (rad)
var rotation: float = 0.0
## 起止参数角。整椭圆为 0 ~ TAU。
var start_param: float = 0.0
var end_param: float = TAU


static func make(c: Vector2, a: float, b: float, rot := 0.0,
		p0 := 0.0, p1 := TAU) -> EntEllipse:
	var e := EntEllipse.new()
	e.type = CadEntity.Type.ELLIPSE
	e.center = c
	e.radius_a = maxf(absf(a), Tol.MIN_RADIUS)
	e.radius_b = maxf(absf(b), Tol.MIN_RADIUS)
	e.rotation = rot
	e.start_param = p0
	e.end_param = p1
	return e


func type_name() -> String:
	return "椭圆" if is_full() else "椭圆弧"


func curve() -> GeoEllipse:
	return GeoEllipse.make(center, radius_a, radius_b, rotation, start_param, end_param)


func get_curves() -> Array[GeoCurve]:
	return [curve()]


func is_full() -> bool:
	return absf(fposmod(end_param - start_param, TAU)) <= Tol.ANGLE


func get_grips() -> PackedVector2Array:
	# 中心 + 长轴两端 + 短轴两端
	var cs := cos(rotation)
	var sn := sin(rotation)
	var ax := Vector2(cs, sn) * radius_a
	var ay := Vector2(-sn, cs) * radius_b
	return PackedVector2Array([center, center + ax, center + ay, center - ax, center - ay])


func move_grip(index: int, pos: Vector2) -> void:
	match index:
		0:
			center = pos
		1:
			# 拖动长轴端点：改长半轴与旋转角
			var v := pos - center
			radius_a = maxf(v.length(), Tol.MIN_RADIUS)
			rotation = v.angle()
		2:
			# 拖动短轴端点：改短半轴
			var v2 := pos - center
			var cs := cos(rotation)
			var sn := sin(rotation)
			var local_y := -sn * v2.x + cs * v2.y
			radius_b = maxf(absf(local_y), Tol.MIN_RADIUS)
		3:
			var v3 := pos - center
			radius_a = maxf(v3.length(), Tol.MIN_RADIUS)
			rotation = v3.angle()
		4:
			var v4 := pos - center
			var cs2 := cos(rotation)
			var sn2 := sin(rotation)
			radius_b = maxf(absf(-sn2 * v4.x + cs2 * v4.y), Tol.MIN_RADIUS)
	invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	var scale := xf.x.length()
	center = xf * center
	radius_a = maxf(radius_a * scale, Tol.MIN_RADIUS)
	radius_b = maxf(radius_b * scale, Tol.MIN_RADIUS)
	rotation += xf.get_rotation()
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make(center, radius_a, radius_b, rotation, start_param, end_param)
	_copy_base_to(e)
	return e


func explode() -> Array[CadEntity]:
	return []


func to_dict() -> Dictionary:
	var d := super.to_dict()
	_put_v2(d, "center", center)
	d["radius_a"] = snappedf(radius_a, 1e-6)
	d["radius_b"] = snappedf(radius_b, 1e-6)
	d["rotation"] = snappedf(rotation, 1e-9)
	d["start_param"] = snappedf(start_param, 1e-9)
	d["end_param"] = snappedf(end_param, 1e-9)
	return d


static func from_dict(d: Dictionary) -> EntEllipse:
	var e := EntEllipse.new()
	e.type = CadEntity.Type.ELLIPSE
	e.read_base_fields(d)
	e.center = _v2(d, "center")
	e.radius_a = maxf(float(d.get("radius_a", 1.0)), Tol.MIN_RADIUS)
	e.radius_b = maxf(float(d.get("radius_b", 1.0)), Tol.MIN_RADIUS)
	e.rotation = float(d.get("rotation", 0.0))
	e.start_param = float(d.get("start_param", 0.0))
	e.end_param = float(d.get("end_param", TAU))
	return e
