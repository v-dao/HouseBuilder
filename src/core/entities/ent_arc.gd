class_name EntArc
extends CadEntity
## 圆弧。对应 DXF 的 ARC（圆心 10，半径 40，起始角 50，终止角 51）。
##
## DXF 的 ARC 恒为**从起始角逆时针扫到终止角**，没有方向标志，
## 因此本类型也不带 ccw 字段，方向固定为逆时针。

var center: Vector2 = Vector2.ZERO
var radius: float = 1.0
## 起始角 (rad)
var start_angle: float = 0.0
## 终止角 (rad)
var end_angle: float = 0.0


static func make(c: Vector2, r: float, a0: float, a1: float) -> EntArc:
	var e := EntArc.new()
	e.type = CadEntity.Type.ARC
	e.center = c
	e.radius = maxf(r, Tol.MIN_RADIUS)
	e.start_angle = a0
	e.end_angle = a1
	return e


## 由圆心与两端点构造（逆时针）
static func make_3p(c: Vector2, p0: Vector2, p1: Vector2) -> EntArc:
	return make(c, c.distance_to(p0), (p0 - c).angle(), (p1 - c).angle())


func type_name() -> String:
	return "圆弧"


func curve() -> GeoArc:
	return GeoArc.make(center, radius, start_angle, end_angle, true)


func _build_curves() -> Array[GeoCurve]:
	return [curve()]


func sweep() -> float:
	return curve().sweep()


func start_point() -> Vector2:
	return curve().start_point()


func end_point() -> Vector2:
	return curve().end_point()


func get_grips() -> PackedVector2Array:
	var c := curve()
	return PackedVector2Array([center, c.start_point(), c.midpoint(), c.end_point()])


func move_grip(index: int, pos: Vector2) -> void:
	match index:
		0:
			center = pos
		1:
			start_angle = (pos - center).angle()
			radius = maxf(center.distance_to(pos), Tol.MIN_RADIUS)
		2:
			# 中点夹点：改半径（保持两端角不变）
			radius = maxf(center.distance_to(pos), Tol.MIN_RADIUS)
		3:
			end_angle = (pos - center).angle()
			radius = maxf(center.distance_to(pos), Tol.MIN_RADIUS)
	invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	# 镜像（行列式 < 0）会反转绕向，而 ARC 只能以逆时针表达，
	# 此时必须交换起止角。镜像的角度映射不是"加旋转角"那样简单，
	# 因此这里不推导角度公式，而是把起点/中点/终点一起变换后按三点重建，
	# 对任意仿射变换都成立。
	var c := curve()
	var p0 := xf * c.start_point()
	var pm := xf * c.midpoint()
	var p1 := xf * c.end_point()
	center = xf * c.center
	radius = maxf(p0.distance_to(center), Tol.MIN_RADIUS)
	var a0 := (p0 - center).angle()
	var am := (pm - center).angle()
	var a1 := (p1 - center).angle()
	# 逆时针从哪一端出发才能经过中点，哪一端就是起点
	if Tol.angle_in_ccw(am, a0, a1):
		start_angle = a0
		end_angle = a1
	else:
		start_angle = a1
		end_angle = a0
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make(center, radius, start_angle, end_angle)
	_copy_base_to(e)
	return e


func explode() -> Array[CadEntity]:
	return []


func length() -> float:
	return radius * sweep()


func to_dict() -> Dictionary:
	var d := super.to_dict()
	_put_v2(d, "center", center)
	d["radius"] = snappedf(radius, 0.000001)
	d["start_angle"] = snappedf(start_angle, 1.0e-9)
	d["end_angle"] = snappedf(end_angle, 1.0e-9)
	return d


static func from_dict(d: Dictionary) -> EntArc:
	var e := EntArc.new()
	e.type = CadEntity.Type.ARC
	e.read_base_fields(d)
	e.center = _v2(d, "center")
	e.radius = maxf(float(d.get("radius", 1.0)), Tol.MIN_RADIUS)
	e.start_angle = float(d.get("start_angle", 0.0))
	e.end_angle = float(d.get("end_angle", 0.0))
	return e
