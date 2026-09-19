class_name GeoArc
extends GeoCurve
## 圆弧。整圆用 sweep = TAU 表示（此时 ccw 为 true，起终点重合）。
##
## 角度约定：模型空间 X 轴正方向为 0，逆时针为正（与建筑制图一致）。
## Y 轴向上，视图变换负责翻转到屏幕坐标。

var center: Vector2 = Vector2.ZERO
var radius: float = 0.0
var start_angle: float = 0.0
var end_angle: float = 0.0
## true = 从 start_angle 逆时针扫到 end_angle；false = 顺时针
var ccw: bool = true


static func make(c: Vector2, r: float, a0: float, a1: float, is_ccw := true) -> GeoArc:
	var a := GeoArc.new()
	a.center = c
	a.radius = absf(r)
	a.start_angle = a0
	a.end_angle = a1
	a.ccw = is_ccw
	return a


## 整圆
static func make_circle(c: Vector2, r: float) -> GeoArc:
	return make(c, r, 0.0, TAU, true)


## 用圆心与两点构造圆弧（取两点所夹的逆时针弧）
static func make_through(c: Vector2, p0: Vector2, p1: Vector2, is_ccw := true) -> GeoArc:
	return make(c, c.distance_to(p0), (p0 - c).angle(), (p1 - c).angle(), is_ccw)


func kind() -> int:
	return Kind.ARC


func is_full_circle() -> bool:
	return absf(sweep()) >= TAU - Tol.ANGLE


## 扫掠角，恒为非负（[0, TAU]）
func sweep() -> float:
	if ccw:
		var s := fposmod(end_angle - start_angle, TAU)
		# 起终点重合时视为整圆
		if s <= Tol.ANGLE and absf(radius) > Tol.MIN_RADIUS:
			return TAU
		return s
	var s := fposmod(start_angle - end_angle, TAU)
	if s <= Tol.ANGLE and absf(radius) > Tol.MIN_RADIUS:
		return TAU
	return s


## 带符号扫掠角：逆时针为正
func signed_sweep() -> float:
	var s := sweep()
	return s if ccw else -s


func angle_at(t: float) -> float:
	if ccw:
		return start_angle + sweep() * t
	return start_angle - sweep() * t


func start_point() -> Vector2:
	return center + Vector2(cos(start_angle), sin(start_angle)) * radius


func end_point() -> Vector2:
	if is_full_circle():
		return start_point()
	return center + Vector2(cos(end_angle), sin(end_angle)) * radius


func point_at(t: float) -> Vector2:
	var a := angle_at(t)
	return center + Vector2(cos(a), sin(a)) * radius


func tangent_at(t: float) -> Vector2:
	var a := angle_at(t)
	# 逆时针时切向为半径方向逆时针旋转 90°
	var r := Vector2(cos(a), sin(a))
	var d := Vector2(-r.y, r.x)
	return d if ccw else -d


func midpoint() -> Vector2:
	return point_at(0.5)


func curve_length() -> float:
	return radius * sweep()


func is_closed() -> bool:
	return is_full_circle()


func bbox() -> Rect2:
	if is_full_circle():
		return Rect2(center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
	# 端点与落在弧内的四个象限点共同决定包围盒
	var pts := PackedVector2Array([start_point(), end_point()])
	for i in range(4):
		var qa := float(i) * PI * 0.5
		if contains_angle(qa):
			pts.append(center + Vector2(cos(qa), sin(qa)) * radius)
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	return Rect2(mn, mx - mn)


## 给定角度是否落在弧上
func contains_angle(a: float) -> bool:
	if is_full_circle():
		return true
	if ccw:
		return Tol.angle_in_ccw(a, start_angle, end_angle)
	return Tol.angle_in_ccw(-a, -start_angle, -end_angle)


## 给定点是否落在弧上（含半径与角度双重判定）
func contains_point(p: Vector2, dist_tol: float = Tol.DIST) -> bool:
	var d := center.distance_to(p)
	if absf(d - radius) > dist_tol:
		return false
	return contains_angle((p - center).angle())


func closest_point(p: Vector2) -> Dictionary:
	var v := p - center
	var d := v.length()
	if d <= Tol.MIN_LEN:
		# 点在圆心：取起点
		var sp := start_point()
		return {"point": sp, "t": 0.0, "dist": p.distance_to(sp)}
	var a := v.angle()
	if contains_angle(a):
		var q := center + v / d * radius
		var t := _angle_to_t(a)
		return {"point": q, "t": t, "dist": p.distance_to(q)}
	# 否则最近点是两端之一
	var sp2 := start_point()
	var ep2 := end_point()
	var ds := p.distance_to(sp2)
	var de := p.distance_to(ep2)
	if ds <= de:
		return {"point": sp2, "t": 0.0, "dist": ds}
	return {"point": ep2, "t": 1.0, "dist": de}


func _angle_to_t(a: float) -> float:
	var sw := sweep()
	if sw <= Tol.ANGLE:
		return 0.0
	var rel := Tol.norm_angle(a - start_angle) if ccw else Tol.norm_angle(start_angle - a)
	return clampf(rel / sw, 0.0, 1.0)


func tessellate(sagitta: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	_append_polyline(out, sagitta)
	return out


func _append_polyline(out: PackedVector2Array, sagitta: float) -> void:
	if radius <= Tol.MIN_RADIUS:
		out.append(center)
		return
	var sw := sweep()
	var n := GeoCurve.arc_segment_count(radius, sw, sagitta)
	for i in range(n + 1):
		out.append(point_at(float(i) / float(n)))


func reversed() -> GeoCurve:
	return GeoArc.make(center, radius, end_angle, start_angle, not ccw)


func transformed(xf: Transform2D) -> GeoCurve:
	# 只支持相似变换（等比缩放 + 旋转 + 平移）。建筑制图中的变换均为相似变换。
	var nc := xf * center
	var x_axis := xf.x
	var scale := x_axis.length()
	var rot := xf.get_rotation()
	var flip := (xf.determinant() < 0.0)
	var a := GeoArc.make(nc, radius * scale, start_angle + rot, end_angle + rot, ccw != flip)
	return a


func feature_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = [
		{"point": start_point(), "type": SnapType.ENDPOINT},
		{"point": center, "type": SnapType.CENTER},
	]
	if not is_full_circle():
		out.append({"point": end_point(), "type": SnapType.ENDPOINT})
		out.append({"point": midpoint(), "type": SnapType.MIDPOINT})
	# 象限点
	for i in range(4):
		var qa := float(i) * PI * 0.5
		if contains_angle(qa):
			out.append({"point": center + Vector2(cos(qa), sin(qa)) * radius, "type": SnapType.QUADRANT})
	return out


# ---------------------------------------------------------------------------
# 求交
# ---------------------------------------------------------------------------

## 圆弧与直线段求交，返回交点数组（可能有 0/1/2 个）
func intersect_seg(seg: GeoSeg, extend_seg := false, extend_arc := false) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var d := seg.b - seg.a
	var f := seg.a - center
	var a := d.dot(d)
	if a <= 1.0e-12:
		return out
	var b := 2.0 * f.dot(d)
	var c := f.dot(f) - radius * radius
	var disc := b * b - 4.0 * a * c
	if disc < -Tol.DIST:
		return out
	if disc < 0.0:
		disc = 0.0
	var sq := sqrt(disc)
	# 注意：循环变量必须来自有类型的数组，否则 sgn 为 Variant，
	# 后续 `sgn * sq` 无法做类型推断（GDScript 会报 "Cannot infer the type"）。
	for sgn in PackedFloat64Array([-1.0, 1.0]):
		var t: float = (-b + sgn * sq) / (2.0 * a)
		if not extend_seg and (t < -Tol.PARAM or t > 1.0 + Tol.PARAM):
			continue
		var p: Vector2 = seg.a + d * t
		if extend_arc or contains_point(p):
			out.append(p)
	# 去重（切点会被算两次）
	if out.size() == 2 and out[0].distance_to(out[1]) <= Tol.POINT:
		out.remove_at(1)
	return out


## 两圆弧求交
func intersect_arc(other: GeoArc, extend_both := false) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var d := center.distance_to(other.center)
	if d <= Tol.MIN_LEN:
		return out  # 同心：无孤立交点
	if d > radius + other.radius + Tol.DIST:
		return out
	if d < absf(radius - other.radius) - Tol.DIST:
		return out
	# 以本弧圆心为原点，连线为 X 轴
	var a_len := (radius * radius - other.radius * other.radius + d * d) / (2.0 * d)
	var h_sq := radius * radius - a_len * a_len
	var h := sqrt(maxf(h_sq, 0.0))
	var dir := (other.center - center) / d
	var base := center + dir * a_len
	var perp := Vector2(-dir.y, dir.x)
	for sgn in PackedFloat64Array([-1.0, 1.0]):
		var p: Vector2 = base + perp * (h * sgn)
		var ok_a := extend_both or contains_point(p)
		var ok_b := extend_both or other.contains_point(p)
		if ok_a and ok_b:
			out.append(p)
	if out.size() == 2 and out[0].distance_to(out[1]) <= Tol.POINT:
		out.remove_at(1)
	return out
