class_name GeoEllipse
extends GeoCurve
## 椭圆 / 椭圆弧。对应 DXF 的 ELLIPSE。
##
## 参数化：point(θ) = center + R(rotation) · (a·cosθ, b·sinθ)
## 其中 a 为长半轴、b 为短半轴。注意 θ 是**参数角**而非几何极角。
##
## 求交等复杂运算不在本类实现，而是由 CurveOps 把椭圆按矢高细分后
## 当作多段线处理 —— 施工图中椭圆用得少，这样取舍能省下大量椭圆代数。

var center: Vector2 = Vector2.ZERO
## 长半轴（沿局部 X）
var radius_a: float = 1.0
## 短半轴（沿局部 Y）
var radius_b: float = 1.0
## 旋转角 (rad)
var rotation: float = 0.0
## 起始参数角 / 终止参数角。整椭圆用 0 ~ TAU。
var start_param: float = 0.0
var end_param: float = TAU


static func make(c: Vector2, a: float, b: float, rot := 0.0,
		p0 := 0.0, p1 := TAU) -> GeoEllipse:
	var e := GeoEllipse.new()
	e.center = c
	e.radius_a = absf(a)
	e.radius_b = absf(b)
	e.rotation = rot
	e.start_param = p0
	e.end_param = p1
	return e


## 由中心 + 长轴端点 + 短长轴比构造（DXF 的表达方式）
static func make_from_axis(c: Vector2, major_end: Vector2, ratio: float,
		p0 := 0.0, p1 := TAU) -> GeoEllipse:
	var v := major_end - c
	var a := v.length()
	return make(c, a, a * absf(ratio), v.angle(), p0, p1)


func kind() -> int:
	return Kind.ELLIPSE


func is_full() -> bool:
	return absf(sweep_param()) >= TAU - Tol.ANGLE


func sweep_param() -> float:
	var s := fposmod(end_param - start_param, TAU)
	if s <= Tol.ANGLE:
		return TAU
	return s


func is_closed() -> bool:
	return is_full()


func point_at(t: float) -> Vector2:
	var th := start_param + sweep_param() * t
	var lx := radius_a * cos(th)
	var ly := radius_b * sin(th)
	var cs := cos(rotation)
	var sn := sin(rotation)
	return center + Vector2(lx * cs - ly * sn, lx * sn + ly * cs)


func tangent_at(t: float) -> Vector2:
	var th := start_param + sweep_param() * t
	# 对 θ 求导
	var lx := -radius_a * sin(th)
	var ly := radius_b * cos(th)
	var cs := cos(rotation)
	var sn := sin(rotation)
	var d := Vector2(lx * cs - ly * sn, lx * sn + ly * cs)
	if d.length() <= Tol.MIN_LEN:
		return Vector2.RIGHT
	var n := d.normalized()
	return n if sweep_param() >= 0.0 else -n


func start_point() -> Vector2:
	return point_at(0.0)


func end_point() -> Vector2:
	if is_full():
		return start_point()
	return point_at(1.0)


func midpoint() -> Vector2:
	return point_at(0.5)


func curve_length() -> float:
	# 椭圆周长无初等闭式解，用 Ramanujan 近似（整椭圆），
	# 不足整椭圆时按参数比例缩放 —— 精度足够用于显示与线型分布。
	var a := maxf(radius_a, radius_b)
	var b := minf(radius_a, radius_b)
	if a <= Tol.MIN_RADIUS:
		return 0.0
	var h := (a - b) * (a - b) / ((a + b) * (a + b))
	var full := PI * (a + b) * (1.0 + 3.0 * h / (10.0 + sqrt(4.0 - 3.0 * h)))
	return full * sweep_param() / TAU


func bbox() -> Rect2:
	if is_full():
		# 整椭圆：由参数方程求极值
		var cs := cos(rotation)
		var sn := sin(rotation)
		var ex := sqrt(radius_a * radius_a * cs * cs + radius_b * radius_b * sn * sn)
		var ey := sqrt(radius_a * radius_a * sn * sn + radius_b * radius_b * cs * cs)
		return Rect2(center - Vector2(ex, ey), Vector2(ex * 2.0, ey * 2.0))
	# 非整椭圆：细分取包围盒（含四个极值点，避免漏掉凸出部分）
	var pts := tessellate(radius_a * 0.01)
	for th in [0.0, PI * 0.5, PI, PI * 1.5]:
		if _param_in_range(th):
			pts.append(_point_at_param(th))
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	return Rect2(mn, mx - mn)


func _point_at_param(th: float) -> Vector2:
	var lx := radius_a * cos(th)
	var ly := radius_b * sin(th)
	var cs := cos(rotation)
	var sn := sin(rotation)
	return center + Vector2(lx * cs - ly * sn, lx * sn + ly * cs)


func _param_in_range(th: float) -> bool:
	if is_full():
		return true
	var sw := sweep_param()
	var d := fposmod(th - start_param, TAU)
	return d <= sw + Tol.ANGLE


## 细分。椭圆按参数均匀细分；矢高与参数步长的关系随曲率变化，
## 这里保守地按最大曲率（长轴端）估算步长。
func tessellate(sagitta: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	_append_polyline(out, sagitta)
	return out


func _append_polyline(out: PackedVector2Array, sagitta: float) -> void:
	var rmin := minf(radius_a, radius_b)
	if rmin <= Tol.MIN_RADIUS:
		out.append(center)
		return
	var sw := sweep_param()
	var n := GeoCurve.arc_segment_count(rmin, sw, sagitta)
	for i in range(n + 1):
		out.append(point_at(float(i) / float(n)))


func closest_point(p: Vector2) -> Dictionary:
	# 数值解法：先粗采样找最近的参数，再在邻域二分细化
	var n := 128
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


func transformed(xf: Transform2D) -> GeoCurve:
	# 只支持相似变换（等比缩放 + 旋转 + 平移）
	var scale := xf.x.length()
	var rot := xf.get_rotation()
	return GeoEllipse.make(xf * center, radius_a * scale, radius_b * scale,
		rotation + rot, start_param, end_param)


## 椭圆不便用解析曲线表达步进方向，特征点只给中心与象限点
func feature_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = [{"point": center, "type": SnapType.CENTER}]
	for i in range(4):
		var th := float(i) * PI * 0.5
		if _param_in_range(th):
			out.append({"point": _point_at_param(th), "type": SnapType.QUADRANT})
	if not is_full():
		out.append({"point": start_point(), "type": SnapType.ENDPOINT})
		out.append({"point": end_point(), "type": SnapType.ENDPOINT})
	return out
