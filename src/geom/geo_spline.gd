class_name GeoSpline
extends GeoCurve
## 样条曲线。采用 Catmull-Rom 插值（过型值点），对应 DXF 中
## "拟合点 + 拟合公差"的表达方式。
##
## 为什么用 Catmull-Rom 而不是 NURBS：
##   施工图里的样条主要用于曲线道路、等高线、异形造型，
##   要求的是"过给定点且光顺"，Catmull-Rom 正好满足且实现简单、求值稳定。
##   NURBS 的权因子/节点矢量在建筑制图中没有实际用途。

## 型值点（曲线严格通过这些点）
var fit_points: PackedVector2Array = PackedVector2Array()
var closed: bool = false
## 张力：0 为标准 Catmull-Rom，越大越紧
var tension: float = 0.5


static func make(pts: PackedVector2Array, is_closed := false) -> GeoSpline:
	var s := GeoSpline.new()
	s.fit_points = pts
	s.closed = is_closed
	return s


func kind() -> int:
	return Kind.SPLINE


func is_closed() -> bool:
	return closed


func segment_count() -> int:
	var n := fit_points.size()
	if n < 2:
		return 0
	return n if closed else n - 1


## 取第 i 段（在 p1 与 p2 之间）的四个控制点
func _seg_control(i: int) -> Array[Vector2]:
	var n := fit_points.size()
	var i0 := i - 1
	var i1 := i
	var i2 := i + 1
	var i3 := i + 2
	if closed:
		i0 = posmod(i0, n)
		i1 = posmod(i1, n)
		i2 = posmod(i2, n)
		i3 = posmod(i3, n)
	else:
		i0 = clampi(i0, 0, n - 1)
		i1 = clampi(i1, 0, n - 1)
		i2 = clampi(i2, 0, n - 1)
		i3 = clampi(i3, 0, n - 1)
	var out: Array[Vector2] = [fit_points[i0], fit_points[i1], fit_points[i2], fit_points[i3]]
	return out


## 第 i 段上参数 u∈[0,1] 处的点。
## 用 Hermite 形式：p(u) = p1·h00 + m1·h10 + p2·h01 + m2·h11，
## 其中切线 m1 = τ(p2-p0)、m2 = τ(p3-p1)。τ = 0.5 即标准 Catmull-Rom。
func _seg_point(i: int, u: float) -> Vector2:
	var c := _seg_control(i)
	var p0 := c[0]
	var p1 := c[1]
	var p2 := c[2]
	var p3 := c[3]
	var m1 := (p2 - p0) * tension
	var m2 := (p3 - p1) * tension
	var u2 := u * u
	var u3 := u2 * u
	var h00 := 2.0 * u3 - 3.0 * u2 + 1.0
	var h10 := u3 - 2.0 * u2 + u
	var h01 := -2.0 * u3 + 3.0 * u2
	var h11 := u3 - u2
	return p1 * h00 + m1 * h10 + p2 * h01 + m2 * h11


func point_at(t: float) -> Vector2:
	var sc := segment_count()
	if sc == 0:
		return fit_points[0] if fit_points.size() > 0 else Vector2.ZERO
	var ft := clampf(t, 0.0, 1.0) * float(sc)
	var i := clampi(int(floorf(ft)), 0, sc - 1)
	return _seg_point(i, ft - float(i))


func tangent_at(t: float) -> Vector2:
	var eps := 1.0e-4
	var t0 := clampf(t - eps, 0.0, 1.0)
	var t1 := clampf(t + eps, 0.0, 1.0)
	var d := point_at(t1) - point_at(t0)
	if d.length() <= Tol.MIN_LEN:
		return Vector2.RIGHT
	return d.normalized()


func start_point() -> Vector2:
	return fit_points[0] if fit_points.size() > 0 else Vector2.ZERO


func end_point() -> Vector2:
	if closed and fit_points.size() > 0:
		return fit_points[0]
	return fit_points[fit_points.size() - 1] if fit_points.size() > 0 else Vector2.ZERO


func midpoint() -> Vector2:
	return point_at(0.5)


## 弧长：按细分折线累加（样条无闭式弧长）
func curve_length() -> float:
	var pts := tessellate(maxf(_rough_scale() * 0.01, 0.05))
	var total := 0.0
	for i in range(pts.size() - 1):
		total += pts[i].distance_to(pts[i + 1])
	return total


func _rough_scale() -> float:
	var bb := _fit_bbox()
	return maxf(maxf(bb.size.x, bb.size.y), 1.0)


func _fit_bbox() -> Rect2:
	if fit_points.is_empty():
		return Rect2()
	var mn := fit_points[0]
	var mx := fit_points[0]
	for p in fit_points:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	return Rect2(mn, mx - mn)


func bbox() -> Rect2:
	return _reflect_bbox(tessellate(maxf(_rough_scale() * 0.005, 0.02)))


func _reflect_bbox(pts: PackedVector2Array) -> Rect2:
	if pts.is_empty():
		return Rect2()
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	return Rect2(mn, mx - mn)


## 细分：按段递归二分，直到弦高误差小于 sagitta。
## 递归深度受限，保证病态输入不会爆栈。
func tessellate(sagitta: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	_append_polyline(out, sagitta)
	return out


func _append_polyline(out: PackedVector2Array, sagitta: float) -> void:
	var sc := segment_count()
	if sc == 0:
		if fit_points.size() > 0:
			out.append(fit_points[0])
		return
	var tol := maxf(sagitta, 1.0e-6)
	for i in range(sc):
		var prev := _seg_point(i, 0.0)
		if out.is_empty():
			out.append(prev)
		_subdivide(out, i, 0.0, prev, 1.0, _seg_point(i, 1.0), tol, 0)
	if closed and out.size() > 1:
		out.append(out[0])


## 递归二分：中点到弦的距离超过 tol 就继续细分
func _subdivide(out: PackedVector2Array, seg: int, u0: float, p0: Vector2,
		u1: float, p1: Vector2, tol: float, depth: int) -> void:
	if depth >= 12:
		out.append(p1)
		return
	var um := (u0 + u1) * 0.5
	var pm := _seg_point(seg, um)
	# 点到弦的距离
	var chord := p1 - p0
	var chord_len := chord.length()
	var dev := 0.0
	if chord_len <= Tol.MIN_LEN:
		dev = p0.distance_to(pm)
	else:
		dev = absf(chord.cross(pm - p0)) / chord_len
	if dev <= tol:
		out.append(p1)
		return
	_subdivide(out, seg, u0, p0, um, pm, tol, depth + 1)
	_subdivide(out, seg, um, pm, u1, p1, tol, depth + 1)


## 最近点：先粗采样再局部细化
func closest_point(p: Vector2) -> Dictionary:
	var n := 96
	var best_t := 0.0
	var best_d := INF
	for i in range(n + 1):
		var t := float(i) / float(n)
		var d := p.distance_squared_to(point_at(t))
		if d < best_d:
			best_d = d
			best_t = t
	var lo := maxf(best_t - 1.0 / float(n), 0.0)
	var hi := minf(best_t + 1.0 / float(n), 1.0)
	for _it in range(40):
		var m1 := lo + (hi - lo) / 3.0
		var m2 := hi - (hi - lo) / 3.0
		if p.distance_squared_to(point_at(m1)) < p.distance_squared_to(point_at(m2)):
			hi = m2
		else:
			lo = m1
	var t2 := (lo + hi) * 0.5
	var q := point_at(t2)
	return {"point": q, "t": t2, "dist": p.distance_to(q)}


func reversed() -> GeoCurve:
	var pts := PackedVector2Array()
	for i in range(fit_points.size() - 1, -1, -1):
		pts.append(fit_points[i])
	return GeoSpline.make(pts, closed)


func transformed(xf: Transform2D) -> GeoCurve:
	var pts := PackedVector2Array()
	pts.resize(fit_points.size())
	for i in range(fit_points.size()):
		pts[i] = xf * fit_points[i]
	return GeoSpline.make(pts, closed)


func feature_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(fit_points.size()):
		out.append({"point": fit_points[i], "type": SnapType.NODE})
	# 段中点
	for i in range(segment_count()):
		out.append({"point": _seg_point(i, 0.5), "type": SnapType.MIDPOINT})
	return out

