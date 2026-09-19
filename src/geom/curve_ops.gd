class_name CurveOps
extends RefCounted
## 曲线运算内核：偏移、分割、修剪、延伸、圆角、倒角、连接、求交。
##
## 设计要点：
##   · 一律以 GeoCurve 为操作对象，图元通过 get_curves() 接入，
##     因此同一套算法对直线、圆弧、多段线通用
##   · 偏移方向约定：**正值表示沿行进方向的左侧**，与 CAD 的直觉一致
##   · 偏移圆弧不改变圆心角，故多段线偏移时 bulge 原样保留、只有顶点移动 ——
##     这是多段线偏移能做到简洁又精确的关键
##
## 已知限制（后续按需增强）：
##   大距离偏移凹多边形会产生自交，AutoCAD 同样如此；
##   需要干净结果时应配合多边形布尔（本文件的 polygon_boolean_* ）做清理。

# ===========================================================================
# 求交基础
# ===========================================================================

## 两无限直线求交。平行/共线返回 null。
static func line_line(p1: Vector2, d1: Vector2, p2: Vector2, d2: Vector2) -> Variant:
	var den := d1.cross(d2)
	if absf(den) <= 1.0e-12:
		return null
	var t := (p2 - p1).cross(d2) / den
	return p1 + d1 * t


## 无限直线与整圆求交，返回 0/1/2 个交点
static func line_circle(p: Vector2, dir: Vector2, c: Vector2, r: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var f := p - c
	var a := dir.dot(dir)
	if a <= 1.0e-15:
		return out
	var b := 2.0 * f.dot(dir)
	var cc := f.dot(f) - r * r
	var disc := b * b - 4.0 * a * cc
	if disc < -Tol.DIST:
		return out
	if disc < 0.0:
		disc = 0.0
	var sq := sqrt(disc)
	for s in PackedFloat64Array([-1.0, 1.0]):
		out.append(p + dir * ((-b + s * sq) / (2.0 * a)))
	if out.size() == 2 and out[0].distance_to(out[1]) <= Tol.POINT:
		out.remove_at(1)
	return out


## 两整圆求交，返回 0/1/2 个交点。同心返回空。
static func circle_circle(c1: Vector2, r1: float, c2: Vector2, r2: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var d := c1.distance_to(c2)
	if d <= Tol.MIN_LEN:
		return out
	if d > r1 + r2 + Tol.DIST:
		return out
	if d < absf(r1 - r2) - Tol.DIST:
		return out
	var a := (r1 * r1 - r2 * r2 + d * d) / (2.0 * d)
	var h_sq := r1 * r1 - a * a
	var h := sqrt(maxf(h_sq, 0.0))
	var dir := (c2 - c1) / d
	var base := c1 + dir * a
	var perp := Vector2(-dir.y, dir.x)
	out.append(base + perp * h)
	out.append(base - perp * h)
	if out.size() == 2 and out[0].distance_to(out[1]) <= Tol.POINT:
		out.remove_at(1)
	return out


## 两条曲线的**支撑曲线**求交（忽略参数范围），用于求偏移后的新顶点。
static func support_intersections(u: GeoCurve, v: GeoCurve) -> Array[Vector2]:
	var ku := u.kind()
	var kv := v.kind()
	if ku == GeoCurve.Kind.SEG and kv == GeoCurve.Kind.SEG:
		var su := u as GeoSeg
		var sv := v as GeoSeg
		var hit = line_line(su.a, su.b - su.a, sv.a, sv.b - sv.a)
		if hit == null:
			return []
		var one: Array[Vector2] = []
		one.append(hit)
		return one
	if ku == GeoCurve.Kind.SEG and kv == GeoCurve.Kind.ARC:
		var s := u as GeoSeg
		var a := v as GeoArc
		return line_circle(s.a, s.b - s.a, a.center, a.radius)
	if ku == GeoCurve.Kind.ARC and kv == GeoCurve.Kind.SEG:
		var s2 := v as GeoSeg
		var a2 := u as GeoArc
		return line_circle(s2.a, s2.b - s2.a, a2.center, a2.radius)
	if ku == GeoCurve.Kind.ARC and kv == GeoCurve.Kind.ARC:
		var a3 := u as GeoArc
		var b3 := v as GeoArc
		return circle_circle(a3.center, a3.radius, b3.center, b3.radius)
	return []


## 任意两条曲线的实际交点（受参数范围约束）。extend 为真时忽略范围。
static func intersect_curves(u: GeoCurve, v: GeoCurve, extend_u := false, extend_v := false) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var ku := u.kind()
	var kv := v.kind()
	if ku == GeoCurve.Kind.SEG and kv == GeoCurve.Kind.SEG:
		var r := (u as GeoSeg).intersect_seg(v as GeoSeg, extend_u, extend_v)
		if r.get("hit", false):
			out.append(r["point"])
		return out
	if ku == GeoCurve.Kind.SEG and kv == GeoCurve.Kind.ARC:
		return (v as GeoArc).intersect_seg(u as GeoSeg, extend_v, extend_u)
	if ku == GeoCurve.Kind.ARC and kv == GeoCurve.Kind.SEG:
		return (u as GeoArc).intersect_seg(v as GeoSeg, extend_u, extend_v)
	if ku == GeoCurve.Kind.ARC and kv == GeoCurve.Kind.ARC:
		var a := u as GeoArc
		var b := v as GeoArc
		if extend_u and extend_v:
			return circle_circle(a.center, a.radius, b.center, b.radius)
		return a.intersect_arc(b, extend_u and extend_v)
	return out


## 展开任意曲线为基本段（线段/圆弧）列表。
## 椭圆与样条没有初等弧长与求交公式，按细分折线参与运算 ——
## 细分矢高取曲线尺度的一个小比例，保证求交精度远高于制图精度（1mm）。
static func decompose(c: GeoCurve) -> Array[GeoCurve]:
	match c.kind():
		GeoCurve.Kind.POLY:
			return (c as GeoPoly).spans()
		GeoCurve.Kind.ELLIPSE, GeoCurve.Kind.SPLINE:
			var pts := c.tessellate(_decompose_sagitta(c))
			var out: Array[GeoCurve] = []
			for i in range(pts.size() - 1):
				if pts[i].distance_to(pts[i + 1]) > Tol.MIN_LEN:
					out.append(GeoSeg.make(pts[i], pts[i + 1]))
			return out
	return [c]


## 细分容差：取曲线尺度的万分之一，但不小于 1e-3mm。
## 10 米跨度的椭圆对应 0.1mm 矢高，比制图精度细一个数量级。
static func _decompose_sagitta(c: GeoCurve) -> float:
	var bb := c.bbox()
	return maxf(maxf(bb.size.x, bb.size.y) * 1.0e-4, 1.0e-3)


## 图元之间求交
static func intersect_entities(a: CadEntity, b: CadEntity, extend_a := false, extend_b := false) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for ca in decompose_all(a):
		for cb in decompose_all(b):
			for p in intersect_curves(ca, cb, extend_a, extend_b):
				var dup := false
				for q in out:
					if q.distance_to(p) <= Tol.POINT:
						dup = true
						break
				if not dup:
					out.append(p)
	return out


static func decompose_all(e: CadEntity) -> Array[GeoCurve]:
	var out: Array[GeoCurve] = []
	for c in e.get_curves():
		for d in decompose(c):
			out.append(d)
	return out


# ===========================================================================
# 弧长定位与分割
# ===========================================================================

## 沿曲线行进 dist 距离处的点。返回 { point, curve_index, t, span_dist }
## 对多段线，curve_index 为所在段序号。
static func point_at_dist(c: GeoCurve, dist: float) -> Dictionary:
	if c.kind() == GeoCurve.Kind.POLY:
		var p := c as GeoPoly
		var acc := 0.0
		for i in range(p.span_count()):
			var sp := p.span(i)
			var l := sp.curve_length()
			if acc + l >= dist - Tol.MIN_LEN or i == p.span_count() - 1:
				var local := 0.0 if l <= Tol.MIN_LEN else clampf((dist - acc) / l, 0.0, 1.0)
				return {"point": sp.point_at(local), "curve_index": i, "t": local, "span_dist": dist - acc}
			acc += l
		return {"point": p.end_point(), "curve_index": maxi(p.span_count() - 1, 0), "t": 1.0, "span_dist": 0.0}
	var total := c.curve_length()
	var t := 0.0 if total <= Tol.MIN_LEN else clampf(dist / total, 0.0, 1.0)
	return {"point": c.point_at(t), "curve_index": 0, "t": t, "span_dist": dist}


## 在参数 t 处把曲线切成两段
static func split_curve(c: GeoCurve, t: float) -> Array[GeoCurve]:
	t = clampf(t, 0.0, 1.0)
	if t <= Tol.PARAM or t >= 1.0 - Tol.PARAM:
		return [c]
	match c.kind():
		GeoCurve.Kind.SEG:
			var s := c as GeoSeg
			var mid := s.point_at(t)
			return [GeoSeg.make(s.a, mid), GeoSeg.make(mid, s.b)]
		GeoCurve.Kind.ARC:
			var a := c as GeoArc
			var am := a.angle_at(t)
			return [
				GeoArc.make(a.center, a.radius, a.start_angle, am, a.ccw),
				GeoArc.make(a.center, a.radius, am, a.end_angle, a.ccw),
			]
	return [c]


## 在弧长 dist 处切分多段线，返回两条多段线
static func split_poly_at_dist(p: GeoPoly, dist: float) -> Array[GeoPoly]:
	var total := p.curve_length()
	if dist <= Tol.MIN_LEN or dist >= total - Tol.MIN_LEN:
		return [p.duplicate_poly()]
	var loc := point_at_dist(p, dist)
	var si: int = loc["curve_index"]
	var lt: float = loc["t"]
	var mid: Vector2 = loc["point"]

	var first := GeoPoly.new()
	var second := GeoPoly.new()
	first.closed = false
	second.closed = false

	# 第一段：原顶点 0..si，末点用切分点
	for i in range(si + 1):
		first.points.append(p.points[i])
		first.bulges.append(p.bulges[i] if i < p.bulges.size() else 0.0)
	first.points.append(mid)
	first.bulges.append(0.0)
	# 切分点所在段的残余部分需要按比例换算 bulge
	if si < p.span_count():
		first.bulges[si] = _partial_bulge(p.span(si), 0.0, lt)

	# 第二段：切分点到末点
	second.points.append(mid)
	var rest_bulge := _partial_bulge(p.span(si), lt, 1.0)
	second.bulges.append(rest_bulge)
	for i in range(si + 1, p.points.size()):
		second.points.append(p.points[i])
		second.bulges.append(p.bulges[i] if i < p.bulges.size() else 0.0)

	first._normalize()
	second._normalize()
	return [first, second]


## 取曲线在参数区间 [t0, t1] 内的部分对应的 bulge
static func _partial_bulge(span: GeoCurve, t0: float, t1: float) -> float:
	if span.kind() == GeoCurve.Kind.SEG:
		return 0.0
	var a := span as GeoArc
	var s0 := a.angle_at(t0)
	var s1 := a.angle_at(t1)
	var theta := (s1 - s0) if a.ccw else (s0 - s1)
	return Bulge.from_angle(theta)


## 保留多段线弧长区间 [d0, d1]，返回新多段线
static func slice_poly(p: GeoPoly, d0: float, d1: float) -> GeoPoly:
	var total := p.curve_length()
	if d0 > d1:
		var tmp := d0
		d0 = d1
		d1 = tmp
	d0 = clampf(d0, 0.0, total)
	d1 = clampf(d1, 0.0, total)
	# 全区间：原样返回
	if d0 <= Tol.MIN_LEN and d1 >= total - Tol.MIN_LEN:
		return p.duplicate_poly()
	# 零长度区间：返回以该点为起终点的退化多段线，
	# 调用方按长度过滤即可丢弃。不能直接返回原曲线。
	if d1 - d0 <= Tol.MIN_LEN:
		var at: Vector2 = point_at_dist(p, d0)["point"]
		return GeoPoly.make(PackedVector2Array([at, at]), PackedFloat64Array([0.0, 0.0]), false)
	# 逐级切分，每次切分后区间起点都对齐到当前曲线的 0
	var src := p.duplicate_poly()
	if d0 > Tol.MIN_LEN:
		src = split_poly_at_dist(src, d0)[1]
	var want := d1 - d0
	if want >= src.curve_length() - Tol.MIN_LEN:
		return src
	return split_poly_at_dist(src, want)[0]


## 从多段线中移除弧长区间 [d0, d1]，返回剩余部分。
## 区间在内部时返回两段（可能与原多段线闭合方式有关）。
static func remove_range_poly(p: GeoPoly, d0: float, d1: float) -> Array[GeoPoly]:
	var total := p.curve_length()
	if d0 > d1:
		var tmp := d0
		d0 = d1
		d1 = tmp
	d0 = clampf(d0, 0.0, total)
	d1 = clampf(d1, 0.0, total)
	var out: Array[GeoPoly] = []
	var head := slice_poly(p, 0.0, d0)
	var tail := slice_poly(p, d1, total)
	if head.curve_length() > Tol.MIN_LEN:
		out.append(head)
	if tail.curve_length() > Tol.MIN_LEN:
		out.append(tail)
	return out


# ===========================================================================
# 偏移
# ===========================================================================

## 偏移单条曲线。d > 0 表示向行进方向的**左侧**偏移。
## 退化（半径被吃穿等）时返回 null。
static func offset_curve(c: GeoCurve, d: float) -> GeoCurve:
	if absf(d) <= Tol.MIN_LEN:
		return c
	match c.kind():
		GeoCurve.Kind.SEG:
			var s := c as GeoSeg
			var n := s.left_normal()
			return GeoSeg.make(s.a + n * d, s.b + n * d)
		GeoCurve.Kind.ARC:
			var a := c as GeoArc
			# 逆时针弧的左侧指向圆心（半径减小），顺时针弧的左侧背离圆心（半径增大）
			var nr := (a.radius - d) if a.ccw else (a.radius + d)
			if nr <= Tol.MIN_RADIUS:
				return null
			return GeoArc.make(a.center, nr, a.start_angle, a.end_angle, a.ccw)
	return null


## 偏移多段线。
## 原理：逐段偏移后，新顶点 = 相邻两条偏移段"支撑曲线"的交点（取靠近原偏移顶点者）。
## 因为偏移不改变圆心角，bulge 数组原样保留。
static func offset_poly(p: GeoPoly, d: float) -> GeoPoly:
	if absf(d) <= Tol.MIN_LEN:
		return p.duplicate_poly()
	var n := p.points.size()
	var sc := p.span_count()
	if n < 2 or sc == 0:
		return null

	# 逐段偏移；任一段退化则整体失败
	var offs: Array[GeoCurve] = []
	for i in range(sc):
		var o := offset_curve(p.span(i), d)
		if o == null:
			return null
		offs.append(o)

	var out := GeoPoly.new()
	out.closed = p.closed
	out.points.resize(n)
	out.bulges = p.bulges.duplicate()
	out._normalize()

	if p.closed:
		# 每个原顶点都是相邻两段的交点
		for i in range(n):
			var prev := offs[(i - 1 + sc) % sc]
			var cur := offs[i]
			out.points[i] = _join_offset(prev, cur, p.points[i])
	else:
		# 首末端点直接取偏移段的端点，中间顶点取交点
		out.points[0] = (offs[0] as GeoCurve).start_point()
		for i in range(1, n - 1):
			out.points[i] = _join_offset(offs[i - 1], offs[i], p.points[i])
		out.points[n - 1] = offs[sc - 1].end_point()
	out._normalize()
	return out


## 求相邻两条偏移段的新交点。取离 near（原顶点）最近的那个候选；
## 平行或求不出交点时退化为两条偏移段端点的中点。
static func _join_offset(prev: GeoCurve, cur: GeoCurve, near: Vector2) -> Vector2:
	var cands := support_intersections(prev, cur)
	if cands.is_empty():
		return (prev.end_point() + cur.start_point()) * 0.5
	var best: Vector2 = cands[0]
	var bd := best.distance_squared_to(near)
	for i in range(1, cands.size()):
		var dd := cands[i].distance_squared_to(near)
		if dd < bd:
			bd = dd
			best = cands[i]
	return best


## 通用偏移入口：对图元偏移，返回新图元列表（闭合曲线偏移可能产生多条）。
static func offset_entity(e: CadEntity, d: float) -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	for c in e.get_curves():
		if c.kind() == GeoCurve.Kind.POLY:
			var np := offset_poly(c as GeoPoly, d)
			if np != null and np.points.size() >= 2:
				var ne := EntPolyline.make_from_geo(np)
				_copy_props(e, ne)
				out.append(ne)
		else:
			var oc := offset_curve(c, d)
			if oc == null:
				continue
			var ent := _curve_to_entity(oc)
			if ent != null:
				_copy_props(e, ent)
				out.append(ent)
	return out


static func _curve_to_entity(c: GeoCurve) -> CadEntity:
	match c.kind():
		GeoCurve.Kind.SEG:
			var s := c as GeoSeg
			return EntLine.make(s.a, s.b)
		GeoCurve.Kind.ARC:
			var a := c as GeoArc
			if a.is_full_circle():
				return EntCircle.make(a.center, a.radius)
			return EntArc.make(a.center, a.radius, a.start_angle, a.end_angle)
		GeoCurve.Kind.ELLIPSE:
			var el := c as GeoEllipse
			return EntEllipse.make(el.center, el.radius_a, el.radius_b,
				el.rotation, el.start_param, el.end_param)
		GeoCurve.Kind.SPLINE:
			return EntSpline.make_from_geo(c as GeoSpline)
	return null


static func _copy_props(src: CadEntity, dst: CadEntity) -> void:
	dst.layer = src.layer
	dst.color = src.color
	dst.aci = src.aci
	dst.linetype = src.linetype
	dst.lineweight = src.lineweight
	dst.linetype_scale = src.linetype_scale
	dst.space = src.space


# ===========================================================================
# 圆角 / 倒角
# ===========================================================================

## 两直线段倒圆角。
## pick_a / pick_b 是用户在两条线上点取的位置，用来确定保留哪一侧的角。
## 返回 { ok, arc: GeoArc, a_end: Vector2, b_start: Vector2, tangent_a, tangent_b }
## 调用方据此把原线段裁到切点并插入圆角弧。
static func fillet_segs(sa: GeoSeg, sb: GeoSeg, r: float,
		pick_a: Vector2, pick_b: Vector2) -> Dictionary:
	# 注意：从 Dictionary 取值得到的是 Variant，必须显式标注类型，
	# 否则 pa 之后的整条推断链（da/db/ta/tb/center/a0/a1）都会编译失败。
	var pa: Vector2 = sa.closest_point(pick_a)["point"]
	var pb: Vector2 = sb.closest_point(pick_b)["point"]
	var corner = line_line(sa.a, sa.b - sa.a, sb.a, sb.b - sb.a)
	# 平行线段无法倒圆角
	if corner == null:
		return {"ok": false}
	var P: Vector2 = corner
	# 由点取位置决定朝哪个方向离开交点
	var da := (pa - P)
	if da.length() <= Tol.MIN_LEN:
		da = (sa.midpoint() - P)
	da = da.normalized()
	var db := (pb - P)
	if db.length() <= Tol.MIN_LEN:
		db = (sb.midpoint() - P)
	db = db.normalized()

	var dot := clampf(da.dot(db), -1.0, 1.0)
	var phi := acos(dot)
	# 共线（同向或反向）无法倒圆角
	if phi <= Tol.ANGLE or absf(phi - PI) <= Tol.ANGLE:
		return {"ok": false}

	var half := phi * 0.5
	var tan_dist := r / tan(half)
	var ta := P + da * tan_dist
	var tb := P + db * tan_dist
	# 圆心在角平分线上
	var bis := (da + db)
	if bis.length() <= Tol.MIN_LEN:
		return {"ok": false}
	bis = bis.normalized()
	var center := P + bis * (r / sin(half))

	var a0 := (ta - center).angle()
	var a1 := (tb - center).angle()
	# 取劣弧：圆角永远是小于 180° 的那一段
	var sweep_ccw := Tol.norm_angle(a1 - a0)
	var arc: GeoArc
	if sweep_ccw <= PI:
		arc = GeoArc.make(center, r, a0, a1, true)
	else:
		arc = GeoArc.make(center, r, a1, a0, true)

	return {
		"ok": true,
		"center": center,
		"radius": r,
		"tangent_a": ta,
		"tangent_b": tb,
		"arc": arc,
		"corner": P,
	}


## 两直线段倒角（斜切）。
## 返回 { ok, cut_a, cut_b, corner }
static func chamfer_segs(sa: GeoSeg, sb: GeoSeg, d1: float, d2: float,
		pick_a: Vector2, pick_b: Vector2) -> Dictionary:
	# 注意：从 Dictionary 取值得到的是 Variant，必须显式标注类型，
	# 否则 pa 之后的整条推断链（da/db/ta/tb/center/a0/a1）都会编译失败。
	var pa: Vector2 = sa.closest_point(pick_a)["point"]
	var pb: Vector2 = sb.closest_point(pick_b)["point"]
	var corner = line_line(sa.a, sa.b - sa.a, sb.a, sb.b - sb.a)
	if corner == null:
		return {"ok": false}
	var P: Vector2 = corner
	var da := (pa - P)
	if da.length() <= Tol.MIN_LEN:
		da = sa.midpoint() - P
	da = da.normalized()
	var db := (pb - P)
	if db.length() <= Tol.MIN_LEN:
		db = sb.midpoint() - P
	db = db.normalized()
	var dot := clampf(da.dot(db), -1.0, 1.0)
	var phi := acos(dot)
	if phi <= Tol.ANGLE or absf(phi - PI) <= Tol.ANGLE:
		return {"ok": false}
	return {
		"ok": true,
		"cut_a": P + da * d1,
		"cut_b": P + db * d2,
		"corner": P,
	}


# ===========================================================================
# 延伸 / 修剪 的定位辅助
# ===========================================================================

## 找出曲线与"边界集合"的所有交点，返回按沿曲线弧长排序的 [距离, 点] 列表
static func crossings_sorted(target: GeoCurve, boundaries: Array[GeoCurve], extend := false) -> Array:
	var total := target.curve_length()
	var found: Array = []
	for b in boundaries:
		var pts := intersect_curves(target, b, extend, true)
		for p in pts:
			var d := _dist_along(target, p)
			var dup := false
			for f in found:
				if absf(float(f[0]) - d) <= Tol.DIST:
					dup = true
					break
			if not dup:
				found.append([d, p])
	found.sort_custom(func(x, y): return float(x[0]) < float(y[0]))
	# 过滤掉超出曲线范围的结果（extend 时可能出现）
	var out: Array = []
	for f in found:
		if float(f[0]) >= -Tol.DIST and float(f[0]) <= total + Tol.DIST:
			out.append(f)
	return out


## 点到曲线起点的**带符号**弧长位置。
## 关键：不能走 closest_point，因为它会把参数截断到 [0,1]，
## 于是"延伸求交"得到的越界交点会被误判为落在端点上而无法过滤。
## 这里用未截断的投影，超出端点的结果会大于曲线长度。
static func _dist_along(c: GeoCurve, p: Vector2) -> float:
	match c.kind():
		GeoCurve.Kind.SEG:
			var s := c as GeoSeg
			var ab := s.b - s.a
			var l2 := ab.length_squared()
			if l2 <= 1.0e-18:
				return 0.0
			return (p - s.a).dot(ab) / l2 * s.curve_length()
		GeoCurve.Kind.ARC:
			var a := c as GeoArc
			var ang := (p - a.center).angle()
			# 归一化到 (-PI, PI]，保留超出端点的正负号
			var rel := Tol.norm_angle_signed(ang - a.start_angle)
			if not a.ccw:
				rel = -rel
			return rel * a.radius
	# 多段线：用最近的那一段（多段线的支撑段已在调用前拆开，这里只作兜底）
	var best := 0.0
	var best_d := INF
	var acc := 0.0
	for i in range((c as GeoPoly).span_count()):
		var sp := (c as GeoPoly).span(i)
		var d := _dist_along(sp, p)
		if absf(d) < best_d:
			best_d = absf(d)
			best = acc + d
		acc += sp.curve_length()
	return best


# ===========================================================================
# 连接 / 合并
# ===========================================================================

## 判断两条曲线能否首尾相连，能则返回合并后的多段线
static func try_join(p1: GeoPoly, p2: GeoPoly) -> GeoPoly:
	if p1.closed or p2.closed:
		return null
	var e1 := p1.end_point()
	var s1 := p1.start_point()
	var e2 := p2.end_point()
	var s2 := p2.start_point()
	# 尝试四种衔接方式
	if e1.distance_to(s2) <= Tol.POINT:
		return _concat(p1, p2)
	if e1.distance_to(e2) <= Tol.POINT:
		return _concat(p1, p2.reversed() as GeoPoly)
	if s1.distance_to(e2) <= Tol.POINT:
		return _concat(p2, p1)
	if s1.distance_to(s2) <= Tol.POINT:
		return _concat(p2.reversed() as GeoPoly, p1)
	return null


static func _concat(a: GeoPoly, b: GeoPoly) -> GeoPoly:
	var out := GeoPoly.new()
	out.closed = false
	for i in range(a.points.size()):
		out.points.append(a.points[i])
		out.bulges.append(a.bulges[i] if i < a.bulges.size() else 0.0)
	# 连接处若首尾重合则跳过重复点
	var start := 0 if a.points.size() == 0 or b.points[0].distance_to(a.points[a.points.size() - 1]) > Tol.POINT else 1
	for i in range(start, b.points.size()):
		out.points.append(b.points[i])
		out.bulges.append(b.bulges[i] if i < b.bulges.size() else 0.0)
	out._normalize()
	return out


## 把图元转成单条多段线（用于 JOIN）
static func entity_to_poly(e: CadEntity) -> GeoPoly:
	var curves := e.get_curves()
	if curves.size() == 1 and curves[0].kind() == GeoCurve.Kind.POLY:
		return (curves[0] as GeoPoly).duplicate_poly()
	# 其他类型：转成等价多段线表达
	var pts := PackedVector2Array()
	var bls := PackedFloat64Array()
	var closed := false
	if e is EntLine:
		var l := e as EntLine
		pts = PackedVector2Array([l.p0, l.p1])
		bls = PackedFloat64Array([0.0, 0.0])
	elif e is EntCircle:
		var ci := e as EntCircle
		# 整圆用两段半圆弧表达
		pts = PackedVector2Array([ci.center + Vector2(ci.radius, 0), ci.center - Vector2(ci.radius, 0)])
		bls = PackedFloat64Array([1.0, 1.0])
		closed = true
	elif e is EntArc:
		var a := e as EntArc
		pts = PackedVector2Array([a.start_point(), a.end_point()])
		bls = PackedFloat64Array([Bulge.from_arc(a.curve()), 0.0])
	return GeoPoly.make(pts, bls, closed)


# ===========================================================================
# 多边形布尔（封装 Godot 的 Geometry2D，供填充边界与区域运算使用）
# ===========================================================================

## 合并。返回轮廓列表（第一条为外轮廓，其余为洞）。
static func polygon_union(a: PackedVector2Array, b: PackedVector2Array) -> Array:
	return Geometry2D.merge_polygons(a, b)


static func polygon_intersect(a: PackedVector2Array, b: PackedVector2Array) -> Array:
	return Geometry2D.intersect_polygons(a, b)


static func polygon_difference(a: PackedVector2Array, b: PackedVector2Array) -> Array:
	return Geometry2D.clip_polygons(a, b)


static func polygon_exclude(a: PackedVector2Array, b: PackedVector2Array) -> Array:
	return Geometry2D.exclude_polygons(a, b)


## 曲线是否闭合（用于判断能否作为填充边界）
static func curve_is_closed(c: GeoCurve) -> bool:
	if c.is_closed():
		return true
	return c.start_point().distance_to(c.end_point()) <= Tol.POINT
