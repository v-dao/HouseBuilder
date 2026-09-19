class_name EntWall
extends CadEntity
## 参数化墙体。建筑软件的核心图元。
##
## 与"手画两条平行线"的本质区别：墙体存的是**中心线 + 厚度 + 洞口**，
## 双线轮廓是推导出来的。带来的直接好处：
##   · 插入门窗 = 往洞口列表加一项，墙线自动断开并生成垛口
##   · 改墙厚 = 改一个数，两侧墙线同时移动，门窗位置不受影响
##   · 算面积、算工程量时中心线与厚度就是现成的数据
##
## 洞口按**沿中心线的弧长**定位（不是坐标），
## 因此墙体移动或改厚后洞口仍然贴在原处。

## 洞口
class Opening:
	extends RefCounted
	## 沿中心线的弧长位置（洞口中心）
	var dist: float = 0.0
	## 洞口宽度（mm）
	var width: float = 900.0
	## 关联的块名（如 M0921），用于门窗表统计
	var block_name: String = ""
	## 是否为窗（窗不画开启弧，统计时区分）
	var is_window: bool = false

	func duplicate_opening() -> Opening:
		var o := Opening.new()
		o.dist = dist
		o.width = width
		o.block_name = block_name
		o.is_window = is_window
		return o


## 中心线。闭合时首尾相连（用于环形外墙）。
var centerline: PackedVector2Array = PackedVector2Array()
## 墙厚（mm）
var thickness: float = 240.0
var closed: bool = false
## 洞口列表
var openings: Array = []


static func make(pts: PackedVector2Array, th := 240.0, is_closed := false) -> EntWall:
	var w := EntWall.new()
	w.type = CadEntity.Type.WALL
	w.centerline = pts
	w.thickness = th
	w.closed = is_closed
	return w


func type_name() -> String:
	return "墙体"


func wall_area() -> float:
	# 墙体面积 = 中心线长度 × 厚度 − 洞口面积
	var l := _centerline_length()
	var a := l * thickness
	for o in openings:
		a -= (o as Opening).width * thickness
	return maxf(a, 0.0)


func _centerline_length() -> float:
	var total := 0.0
	var n := centerline.size()
	if n < 2:
		return 0.0
	var limit := n if closed else n - 1
	for i in range(limit):
		total += centerline[i].distance_to(centerline[(i + 1) % n])
	return total


## 沿中心线弧长定位。返回 { point, seg_index, t }
func point_at_dist(d: float) -> Dictionary:
	var n := centerline.size()
	if n < 2:
		return {"point": Vector2.ZERO, "seg_index": 0, "t": 0.0}
	var acc := 0.0
	var limit := n if closed else n - 1
	for i in range(limit):
		var a := centerline[i]
		var b := centerline[(i + 1) % n]
		var l := a.distance_to(b)
		if acc + l >= d - Tol.MIN_LEN or i == limit - 1:
			var t := 0.0 if l <= Tol.MIN_LEN else clampf((d - acc) / l, 0.0, 1.0)
			return {"point": a.lerp(b, t), "seg_index": i, "t": t}
		acc += l
	return {"point": centerline[n - 1], "seg_index": limit - 1, "t": 1.0}


## 墙体在弧长 d 处的方向（单位向量）
func direction_at_dist(d: float) -> Vector2:
	var r := point_at_dist(d)
	var i: int = r["seg_index"]
	var n := centerline.size()
	if n < 2:
		return Vector2.RIGHT
	var a := centerline[i]
	var b := centerline[(i + 1) % n]
	var v := b - a
	return v.normalized() if v.length() > Tol.MIN_LEN else Vector2.RIGHT


# ---------------------------------------------------------------------------
# 轮廓生成
# ---------------------------------------------------------------------------

## 生成墙体轮廓。做法：把中心线按洞口切成若干段，
## 每段向两侧偏移 t/2 得到一个小矩形，洞口处自然形成垛口（门窗洞口的侧壁）。
func get_curves() -> Array[GeoCurve]:
	var out: Array[GeoCurve] = []
	var spans := solid_spans()
	var half := thickness * 0.5
	for sp in spans:
		var pts: PackedVector2Array = sp
		if pts.size() < 2:
			continue
		# 逐段生成矩形，段与段之间靠端点重合衔接，转角处由相邻矩形的端边形成垛口
		for i in range(pts.size() - 1):
			var a := pts[i]
			var b := pts[i + 1]
			var v := b - a
			var l := v.length()
			if l <= Tol.MIN_LEN:
				continue
			var u := v / l
			var nrm := Vector2(-u.y, u.x) * half
			var p0 := a + nrm
			var p1 := b + nrm
			var p2 := b - nrm
			var p3 := a - nrm
			out.append(GeoSeg.make(p0, p1))
			out.append(GeoSeg.make(p1, p2))
			out.append(GeoSeg.make(p2, p3))
			out.append(GeoSeg.make(p3, p0))
	return out


## 墙体实心段的多边形（用于房间面积的布尔运算）。
## 与 get_curves 同源，但以闭合多边形返回，便于交给 Geometry2D 做并集。
func solid_polygons() -> Array:
	var out: Array = []
	var half := thickness * 0.5
	for sp in solid_spans():
		var pts: PackedVector2Array = sp
		for i in range(pts.size() - 1):
			var a := pts[i]
			var b := pts[i + 1]
			var v := b - a
			var l := v.length()
			if l <= Tol.MIN_LEN:
				continue
			var u := v / l
			var nrm := Vector2(-u.y, u.x) * half
			out.append(PackedVector2Array([a + nrm, b + nrm, b - nrm, a - nrm]))
	return out


## 去掉洞口后的中心线实心段列表。
## 每段是若干折点；洞口处切断，相邻段的端边即为门窗垛口的侧壁。
func solid_spans() -> Array:
	var out: Array = []
	var total := _centerline_length()
	if total <= Tol.MIN_LEN:
		return out
	# 收集洞口区间
	var ranges: Array = []
	for o in openings:
		var op := o as Opening
		var d0 := op.dist - op.width * 0.5
		var d1 := op.dist + op.width * 0.5
		ranges.append([maxf(d0, 0.0), minf(d1, total)])
	ranges.sort_custom(func(x, y): return float(x[0]) < float(y[0]))
	# 合并重叠区间
	var merged: Array = []
	for r in ranges:
		if merged.is_empty():
			merged.append(r)
			continue
		var last: Array = merged[merged.size() - 1]
		if float(r[0]) <= float(last[1]) + Tol.MIN_LEN:
			last[1] = maxf(float(last[1]), float(r[1]))
		else:
			merged.append(r)
	# 生成实心段
	var cursor := 0.0
	for r in merged:
		var d0 := float(r[0])
		var d1 := float(r[1])
		if d0 > cursor + Tol.MIN_LEN:
			var piece := _sub_polyline(cursor, d0)
			if piece.size() >= 2:
				out.append(piece)
		cursor = maxf(cursor, d1)
	if cursor < total - Tol.MIN_LEN or (closed and merged.is_empty()):
		var piece2 := _sub_polyline(cursor, total)
		if piece2.size() >= 2:
			out.append(piece2)
	# 闭合墙体且无洞口时，整圈就是一段
	if closed and merged.is_empty() and out.is_empty():
		var all := centerline.duplicate()
		if all.size() > 1 and all[0].distance_to(all[all.size() - 1]) > Tol.POINT:
			all.append(all[0])
		out.append(all)
	return out


## 取中心线上弧长区间 [d0, d1] 的折点
func _sub_polyline(d0: float, d1: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if d1 - d0 <= Tol.MIN_LEN:
		return out
	out.append(point_at_dist(d0)["point"])
	# 中间的原有顶点
	var acc := 0.0
	var n := centerline.size()
	var limit := n if closed else n - 1
	for i in range(limit):
		var a := centerline[i]
		var b := centerline[(i + 1) % n]
		var l := a.distance_to(b)
		var seg_end := acc + l
		if seg_end > d0 + Tol.MIN_LEN and seg_end < d1 - Tol.MIN_LEN and i + 1 < n:
			out.append(centerline[i + 1])
		acc = seg_end
	out.append(point_at_dist(d1)["point"])
	return out


## 洞口处的门窗块引用（供门窗表与渲染使用）。
## 返回未加入文档的 EntInsert 数组，由调用方决定是否插入。
func opening_inserts() -> Array:
	var out: Array = []
	for o in openings:
		var op := o as Opening
		if op.block_name == "":
			continue
		var r := point_at_dist(op.dist)
		var ins := EntInsert.make(op.block_name, r["point"])
		ins.rotation = direction_at_dist(op.dist).angle()
		# 块以左下角为基点、沿 +X 展开，旋转后正好沿墙向
		ins.layer = layer
		out.append(ins)
	return out


# ---------------------------------------------------------------------------
# 编辑
# ---------------------------------------------------------------------------

func add_opening(dist: float, width: float, block_name: String, is_window: bool) -> bool:
	var total := _centerline_length()
	if dist - width * 0.5 < -Tol.MIN_LEN or dist + width * 0.5 > total + Tol.MIN_LEN:
		return false
	# 与已有洞口重叠则拒绝，避免出现负长度的墙段
	for o in openings:
		var op := o as Opening
		if absf(op.dist - dist) < (op.width + width) * 0.5 - Tol.MIN_LEN:
			return false
	var n := Opening.new()
	n.dist = dist
	n.width = width
	n.block_name = block_name
	n.is_window = is_window
	openings.append(n)
	invalidate_bbox()
	return true


func remove_opening_at(dist: float, tolerance := 200.0) -> bool:
	for i in range(openings.size()):
		var op: Opening = openings[i]
		if absf(op.dist - dist) <= tolerance:
			openings.remove_at(i)
			invalidate_bbox()
			return true
	return false


func get_grips() -> PackedVector2Array:
	var out := centerline.duplicate()
	# 洞口中心也作为夹点，便于拖动门窗位置
	for o in openings:
		out.append(point_at_dist((o as Opening).dist)["point"])
	return out


func get_stretch_points() -> PackedVector2Array:
	return centerline.duplicate()


func move_grip(i: int, p: Vector2) -> void:
	if i < centerline.size():
		centerline[i] = p
		invalidate_bbox()
		return
	# 拖动洞口夹点：改洞口沿墙的位置
	var oi := i - centerline.size()
	if oi >= 0 and oi < openings.size():
		var op: Opening = openings[oi]
		# 找该点在中心线上的最近弧长
		op.dist = _dist_along_centerline(p)
		invalidate_bbox()


func _dist_along_centerline(p: Vector2) -> float:
	var best := 0.0
	var best_d := INF
	var acc := 0.0
	var n := centerline.size()
	var limit := n if closed else n - 1
	for i in range(limit):
		var a := centerline[i]
		var b := centerline[(i + 1) % n]
		var ab := b - a
		var l2 := ab.length_squared()
		var t := 0.0 if l2 <= 1.0e-18 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var q := a + ab * t
		var d := p.distance_to(q)
		if d < best_d:
			best_d = d
			best = acc + t * a.distance_to(b)
		acc += a.distance_to(b)
	return best


func transform_by(xf: Transform2D) -> void:
	for i in range(centerline.size()):
		centerline[i] = xf * centerline[i]
	# 厚度按缩放比例变化（相似变换假设 X/Y 等比）
	thickness *= xf.x.length()
	for o in openings:
		(o as Opening).width *= xf.x.length()
	invalidate_bbox()


func clone() -> CadEntity:
	var w := EntWall.new()
	w.type = CadEntity.Type.WALL
	w.centerline = centerline.duplicate()
	w.thickness = thickness
	w.closed = closed
	for o in openings:
		w.openings.append((o as Opening).duplicate_opening())
	_copy_base_to(w)
	return w


## 拆解为墙线的多段线（失去参数化能力，但可用于交给其他软件）
func explode() -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	for c in get_curves():
		if c.kind() == GeoCurve.Kind.SEG:
			var s := c as GeoSeg
			var e := EntLine.make(s.a, s.b)
			_copy_base_to(e)
			out.append(e)
	return out


## 中心线作为捕捉特征（端点/中点）
func feature_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in centerline:
		out.append({"point": p, "type": SnapType.ENDPOINT})
	for o in openings:
		var op := o as Opening
		var r := point_at_dist(op.dist)
		out.append({"point": r["point"], "type": SnapType.NODE})
		# 从 Dictionary 取值是 Variant，必须显式标注类型
		var d0: Vector2 = point_at_dist(maxf(op.dist - op.width * 0.5, 0.0))["point"]
		var d1: Vector2 = point_at_dist(minf(op.dist + op.width * 0.5, _centerline_length()))["point"]
		out.append({"point": d0, "type": SnapType.ENDPOINT})
		out.append({"point": d1, "type": SnapType.ENDPOINT})
	return out


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["centerline"] = _pts_to_arr(centerline)
	d["thickness"] = snappedf(thickness, 1e-6)
	d["closed"] = closed
	var ops := []
	for o in openings:
		var op := o as Opening
		ops.append({
			"dist": snappedf(op.dist, 1e-6),
			"width": snappedf(op.width, 1e-6),
			"block_name": op.block_name,
			"is_window": op.is_window,
		})
	d["openings"] = ops
	return d


static func from_dict(d: Dictionary) -> EntWall:
	var w := EntWall.new()
	w.type = CadEntity.Type.WALL
	w.read_base_fields(d)
	w.centerline = _arr_to_pts(d.get("centerline", []))
	w.thickness = float(d.get("thickness", 240.0))
	w.closed = bool(d.get("closed", false))
	var ops = d.get("openings", [])
	for o in (ops as Array):
		var od: Dictionary = o
		var op := Opening.new()
		op.dist = float(od.get("dist", 0.0))
		op.width = float(od.get("width", 900.0))
		op.block_name = String(od.get("block_name", ""))
		op.is_window = bool(od.get("is_window", false))
		w.openings.append(op)
	return w
