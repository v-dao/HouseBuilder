class_name GeoSeg
extends GeoCurve
## 直线段。

var a: Vector2 = Vector2.ZERO
var b: Vector2 = Vector2.ZERO


static func make(p0: Vector2, p1: Vector2) -> GeoSeg:
	var s := GeoSeg.new()
	s.a = p0
	s.b = p1
	return s


func kind() -> int:
	return Kind.SEG


func start_point() -> Vector2:
	return a


func end_point() -> Vector2:
	return b


func midpoint() -> Vector2:
	return (a + b) * 0.5


func point_at(t: float) -> Vector2:
	return a.lerp(b, t)


func tangent_at(_t: float) -> Vector2:
	var d := b - a
	var l := d.length()
	if l <= Tol.MIN_LEN:
		return Vector2.RIGHT
	return d / l


func curve_length() -> float:
	return a.distance_to(b)


func direction() -> Vector2:
	var d := b - a
	var l := d.length()
	if l <= Tol.MIN_LEN:
		return Vector2.RIGHT
	return d / l


## 左法向（沿切向逆时针旋转 90°）
func left_normal() -> Vector2:
	var d := direction()
	return Vector2(-d.y, d.x)


func bbox() -> Rect2:
	return Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), Vector2(absf(b.x - a.x), absf(b.y - a.y)))


func closest_point(p: Vector2) -> Dictionary:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq <= Tol.MIN_LEN * Tol.MIN_LEN:
		return {"point": a, "t": 0.0, "dist": p.distance_to(a)}
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	var q := a + ab * t
	return {"point": q, "t": t, "dist": p.distance_to(q)}


func tessellate(_sagitta: float) -> PackedVector2Array:
	return PackedVector2Array([a, b])


func _append_polyline(out: PackedVector2Array, _sagitta: float) -> void:
	out.append(a)
	out.append(b)


func reversed() -> GeoCurve:
	return GeoSeg.make(b, a)


func transformed(xf: Transform2D) -> GeoCurve:
	return GeoSeg.make(xf * a, xf * b)


func feature_points() -> Array[Dictionary]:
	return [
		{"point": a, "type": SnapType.ENDPOINT},
		{"point": b, "type": SnapType.ENDPOINT},
		{"point": midpoint(), "type": SnapType.MIDPOINT},
	]


## 两条直线段求交。返回 { hit: bool, point: Vector2, t: float, u: float }
## t 为本段参数，u 为另一段参数。
func intersect_seg(other: GeoSeg, extend_a := false, extend_b := false) -> Dictionary:
	var p := a
	var r := b - a
	var q := other.a
	var s := other.b - other.a
	var rxs := r.cross(s)
	var qp := q - p
	if absf(rxs) <= 1.0e-12:
		# 平行或共线：视为无唯一交点
		return {"hit": false}
	var t := qp.cross(s) / rxs
	var u := qp.cross(r) / rxs
	var ok_t := (t >= -Tol.PARAM and t <= 1.0 + Tol.PARAM) if not extend_a else true
	var ok_u := (u >= -Tol.PARAM and u <= 1.0 + Tol.PARAM) if not extend_b else true
	if not (ok_t and ok_u):
		return {"hit": false}
	return {"hit": true, "point": p + r * t, "t": t, "u": u}
