class_name GeoPoly
extends GeoCurve
## 带 bulge 的多段线，与 DXF 的 LWPOLYLINE 一一对应。
##
## bulges[i] 描述从 points[i] 到 points[i+1] 的那一段的圆弧参数；
## 闭合多段线时最后一段由 points[n-1] 回到 points[0]，其 bulge 为 bulges[n-1]；
## 非闭合多段线的 bulges[n-1] 无意义（恒为 0）。

var points: PackedVector2Array = PackedVector2Array()
var bulges: PackedFloat64Array = PackedFloat64Array()
var closed: bool = false


static func make(pts: PackedVector2Array, bls: PackedFloat64Array = PackedFloat64Array(), is_closed := false) -> GeoPoly:
	var p := GeoPoly.new()
	p.points = pts
	p.bulges = bls
	p.closed = is_closed
	p._normalize()
	return p


## 保证 bulges 与 points 等长，避免越界
func _normalize() -> void:
	var n := points.size()
	if bulges.size() != n:
		var b := PackedFloat64Array()
		b.resize(n)
		for i in range(n):
			b[i] = bulges[i] if i < bulges.size() else 0.0
		bulges = b


func kind() -> int:
	return Kind.POLY


func vertex_count() -> int:
	return points.size()


## 段数
func span_count() -> int:
	var n := points.size()
	if n < 2:
		return 0
	return n if closed else n - 1


func span(i: int) -> GeoCurve:
	var n := points.size()
	var j := (i + 1) % n
	var b := bulges[i] if i < bulges.size() else 0.0
	return Bulge.span_to_curve(points[i], points[j], b)


## 展开为逐段曲线列表
func spans() -> Array[GeoCurve]:
	var out: Array[GeoCurve] = []
	for i in range(span_count()):
		out.append(span(i))
	return out


func start_point() -> Vector2:
	return points[0] if points.size() > 0 else Vector2.ZERO


func end_point() -> Vector2:
	if points.size() == 0:
		return Vector2.ZERO
	return points[0] if closed else points[points.size() - 1]


func midpoint() -> Vector2:
	var n := span_count()
	if n == 0:
		return start_point()
	return point_at(0.5)


## 参数 t 按"整条多段线的弧长比例"分布
func point_at(t: float) -> Vector2:
	var total := curve_length()
	if total <= Tol.MIN_LEN:
		return start_point()
	var target := clampf(t, 0.0, 1.0) * total
	var acc := 0.0
	for i in range(span_count()):
		var c := span(i)
		var l := c.curve_length()
		if acc + l >= target - Tol.MIN_LEN:
			var local := 0.0 if l <= Tol.MIN_LEN else (target - acc) / l
			return c.point_at(clampf(local, 0.0, 1.0))
		acc += l
	return end_point()


func tangent_at(t: float) -> Vector2:
	var total := curve_length()
	if total <= Tol.MIN_LEN:
		return Vector2.RIGHT
	var target := clampf(t, 0.0, 1.0) * total
	var acc := 0.0
	for i in range(span_count()):
		var c := span(i)
		var l := c.curve_length()
		if acc + l >= target - Tol.MIN_LEN:
			var local := 0.0 if l <= Tol.MIN_LEN else (target - acc) / l
			return c.tangent_at(clampf(local, 0.0, 1.0))
		acc += l
	return Vector2.RIGHT


func curve_length() -> float:
	var total := 0.0
	for i in range(span_count()):
		total += span(i).curve_length()
	return total


func is_closed() -> bool:
	return closed


func bbox() -> Rect2:
	if points.size() == 0:
		return Rect2()
	var mn := points[0]
	var mx := points[0]
	for p in points:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	# 圆弧段可能鼓出顶点包围盒，需并入
	for i in range(span_count()):
		var c := span(i)
		if c.kind() == Kind.ARC:
			var ab := c.bbox()
			mn = Vector2(minf(mn.x, ab.position.x), minf(mn.y, ab.position.y))
			mx = Vector2(maxf(mx.x, ab.position.x + ab.size.x), maxf(mx.y, ab.position.y + ab.size.y))
	return Rect2(mn, mx - mn)


func closest_point(p: Vector2) -> Dictionary:
	var best := {"point": start_point(), "t": 0.0, "dist": INF}
	var total := curve_length()
	if total <= Tol.MIN_LEN:
		best["dist"] = p.distance_to(start_point())
		return best
	var acc := 0.0
	for i in range(span_count()):
		var c := span(i)
		var l := c.curve_length()
		var r := c.closest_point(p)
		if r["dist"] < best["dist"]:
			best = {
				"point": r["point"],
				"t": (acc + l * float(r["t"])) / total,
				"dist": r["dist"],
			}
		acc += l
	return best


func tessellate(sagitta: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	_append_polyline(out, sagitta)
	return out


func _append_polyline(out: PackedVector2Array, sagitta: float) -> void:
	# 逐段细分，避免在相邻段接缝处插入重复点
	for i in range(span_count()):
		var seg := span(i).tessellate(sagitta)
		var start_idx := 0 if out.size() == 0 else 1
		for k in range(start_idx, seg.size()):
			out.append(seg[k])
	if closed and out.size() > 1:
		out.append(out[0])


func reversed() -> GeoCurve:
	var n := points.size()
	var pts := PackedVector2Array()
	var bls := PackedFloat64Array()
	for i in range(n - 1, -1, -1):
		pts.append(points[i])
	bls.resize(n)
	if closed:
		# 反转后 w[i] = v[n-1-i]；新段 i 由 w[i] 指向 w[i+1]（模 n），
		# 即由 v[n-1-i] 指向 v[n-2-i]，等同于原段 j = (n-2-i) mod n 的反向。
		# 反向的圆弧绕向相反，故 bulge 取负。
		for i in range(n):
			var src := posmod(n - 2 - i, n)
			bls[i] = -bulges[src] if src < bulges.size() else 0.0
	else:
		# 开口时末段的 bulge 无意义，置 0；前 m 段由原段倒序取负而来
		var m := span_count()
		for i in range(n):
			bls[i] = 0.0
		for i in range(m):
			var src := m - 1 - i
			bls[i] = -bulges[src] if src >= 0 and src < bulges.size() else 0.0
	return GeoPoly.make(pts, bls, closed)


func transformed(xf: Transform2D) -> GeoCurve:
	var pts := PackedVector2Array()
	pts.resize(points.size())
	for i in range(points.size()):
		pts[i] = xf * points[i]
	var flip := xf.determinant() < 0.0
	var bls := bulges.duplicate()
	if flip:
		# 镜像变换会反转绕向，bulge 符号需取反
		for i in range(bls.size()):
			bls[i] = -bls[i]
	return GeoPoly.make(pts, bls, closed)


func feature_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(points.size()):
		out.append({"point": points[i], "type": SnapType.ENDPOINT})
	for i in range(span_count()):
		var c := span(i)
		out.append({"point": c.midpoint(), "type": SnapType.MIDPOINT})
		if c.kind() == Kind.ARC:
			out.append({"point": c.center, "type": SnapType.CENTER})
			for f in c.feature_points():
				if int(f["type"]) == SnapType.QUADRANT:
					out.append(f)
	return out


## 去掉连续重复点与共线冗余点，返回是否发生了改变
func dedupe(tolerance: float = Tol.POINT) -> bool:
	var n := points.size()
	if n < 2:
		return false
	var pts := PackedVector2Array()
	var bls := PackedFloat64Array()
	var changed := false
	for i in range(n):
		var is_last := (i == n - 1)
		if pts.size() > 0 and points[i].distance_to(pts[pts.size() - 1]) <= tolerance:
			changed = true
			if is_last and closed:
				# 末点与首点重合时，需把末段的 bulge 转移到首段之前的段
				pass
			continue
		pts.append(points[i])
		bls.append(bulges[i] if i < bulges.size() else 0.0)
	if changed:
		points = pts
		bulges = bls
		_normalize()
	return changed
