class_name RoomFinder
extends RefCounted
## 房间区域求解。
##
## 做法分三步：
##   1. 用**墙体中心线**构成平面剖分（不是墙体轮廓！）
##   2. 追踪出包含给定点的那个面 —— 得到房间的轴线多边形
##   3. 按每条边所属墙体的厚度向内偏移半个墙厚，得到净尺寸多边形
##
## 为什么剖分要用中心线而不是墙体轮廓：
## 墙体轮廓由逐段矩形拼成，转角处相邻矩形相互重叠，会产生大量内部小边，
## 面追踪会掉进这些微小面里，算出的面积比真实值小一个数量级（已实测）。
## 中心线是规范的平面网格，交点清晰，追踪稳定。
##
## 面积按"到墙体内表面"计量，符合建筑面积的计算习惯（门窗洞口不扣减）。

## 顶点量化精度（mm），用于把浮点坐标归并成同一顶点
const VERTEX_QUANT := 0.01


## 求包含点 p 的房间净尺寸多边形。walls 为 EntWall 数组。
static func find_room(walls: Array, p: Vector2) -> PackedVector2Array:
	if walls.is_empty():
		return PackedVector2Array()
	var raw := _collect_centerlines(walls)
	if raw.is_empty():
		return PackedVector2Array()
	var edges := _split_at_intersections(raw)
	if edges.is_empty():
		return PackedVector2Array()
	var graph := _build_graph(edges)
	if graph.is_empty():
		return PackedVector2Array()
	var start := _nearest_edge(edges, p)
	if start.is_empty():
		return PackedVector2Array()
	# 点取位置落在墙体实体里：明确判为无效。
	# 此时"最近边"就在脚下，追踪哪一侧都没有意义，
	# 事后靠几何校验去挡会出现边界上的模糊情况，不如在这里直接判负。
	if float(start[2]) < _half_thickness_at(start[0], start[1], edges):
		return PackedVector2Array()
	var traced := _trace_face(graph, start[0], start[1], p)
	if traced.size() < 3:
		return PackedVector2Array()
	var result := _inset_to_wall_faces(traced, edges)
	if result.size() < 3:
		return PackedVector2Array()
	# 最终校验：点必须落在内缩后的多边形内部。
	# 少了这一步，点在墙上或建筑外时会追踪到墙体外侧的那个环
	# （它同样是闭合的），返回一个看似有效却无意义的区域。
	if not GbHatch.point_in_polygon(p, result):
		return PackedVector2Array()
	return result


# ---------------------------------------------------------------------------
# 1) 中心线
# ---------------------------------------------------------------------------

## 返回 [a, b, 半墙厚] 的边列表
static func _collect_centerlines(walls: Array) -> Array:
	var out: Array = []
	for w in walls:
		var wall := w as EntWall
		if wall == null:
			continue
		var pts := wall.centerline
		var n := pts.size()
		if n < 2:
			continue
		var limit := n if wall.closed else n - 1
		for i in range(limit):
			var a := pts[i]
			var b := pts[(i + 1) % n]
			if a.distance_to(b) > Tol.MIN_LEN:
				out.append([a, b, wall.thickness * 0.5])
	return out


# ---------------------------------------------------------------------------
# 2) 在交点处打断
# ---------------------------------------------------------------------------

static func _split_at_intersections(edges: Array) -> Array:
	var cuts: Array = []
	for i in range(edges.size()):
		cuts.append([0.0, 1.0])
	for i in range(edges.size()):
		var a0: Vector2 = edges[i][0]
		var a1: Vector2 = edges[i][1]
		var da := a1 - a0
		for j in range(i + 1, edges.size()):
			var b0: Vector2 = edges[j][0]
			var b1: Vector2 = edges[j][1]
			var db := b1 - b0
			var den := da.cross(db)
			if absf(den) <= 1.0e-12:
				continue
			var t := (b0 - a0).cross(db) / den
			var u := (b0 - a0).cross(da) / den
			if t > -1.0e-9 and t < 1.0 + 1.0e-9 and u > -1.0e-9 and u < 1.0 + 1.0e-9:
				(cuts[i] as Array).append(clampf(t, 0.0, 1.0))
				(cuts[j] as Array).append(clampf(u, 0.0, 1.0))
	var out: Array = []
	for i in range(edges.size()):
		var a: Vector2 = edges[i][0]
		var b: Vector2 = edges[i][1]
		var half: float = edges[i][2]
		var ts: Array = cuts[i]
		ts.sort()
		var prev := 0.0
		for t in ts:
			var tv := float(t)
			if tv - prev > 1.0e-7:
				out.append([a.lerp(b, prev), a.lerp(b, tv), half])
			prev = tv
		if 1.0 - prev > 1.0e-7:
			out.append([a.lerp(b, prev), b, half])
	return out


# ---------------------------------------------------------------------------
# 3) 建图与面追踪
# ---------------------------------------------------------------------------

static func _vkey(p: Vector2) -> String:
	return "%d,%d" % [int(round(p.x / VERTEX_QUANT)), int(round(p.y / VERTEX_QUANT))]


static func _key_pos(k: String) -> Vector2:
	var parts := k.split(",")
	return Vector2(float(parts[0].to_int()) * VERTEX_QUANT, float(parts[1].to_int()) * VERTEX_QUANT)


## 顶点 -> 出边列表，每项为 [邻居键, 邻居坐标, 极角, 半墙厚]，按极角升序
static func _build_graph(edges: Array) -> Dictionary:
	var g := {}
	for e in edges:
		var a: Vector2 = e[0]
		var b: Vector2 = e[1]
		var half: float = e[2]
		var ka := _vkey(a)
		var kb := _vkey(b)
		if ka == kb:
			continue
		_add_half_edge(g, ka, kb, b, half)
		_add_half_edge(g, kb, ka, a, half)
	for k in g.keys():
		var list: Array = g[k]
		list.sort_custom(func(x, y): return float(x[2]) < float(y[2]))
	return g


static func _add_half_edge(g: Dictionary, from_key: String, to_key: String,
		to_pos: Vector2, half: float) -> void:
	if not g.has(from_key):
		g[from_key] = []
	var fp := _key_pos(from_key)
	var ang := (to_pos - fp).angle()
	var list: Array = g[from_key]
	for item in list:
		if String(item[0]) == to_key:
			return
	list.append([to_key, to_pos, ang, half])


## 返回 [a, b, 到该边的距离]
static func _nearest_edge(edges: Array, p: Vector2) -> Array:
	var best: Array = []
	var best_d := INF
	for e in edges:
		var a: Vector2 = e[0]
		var b: Vector2 = e[1]
		var ab := b - a
		var l2 := ab.length_squared()
		var t := 0.0 if l2 <= 1.0e-18 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var d := p.distance_to(a + ab * t)
		if d < best_d - 1.0e-9:
			best_d = d
			best = [a, b, d]
	return best


## 从有向边出发，追踪位于 p 那一侧的面。
## 规则：在终点 v 处把 v 的出边按极角排序，取反向边的前一条（环状）。
## 这保证面始终在当前边的左侧，走出的闭合环即为该面的边界。
## 以三角形为例可验证：A(0,0)->B(1,0) 起点，B 处出边按角排序为 [B->C(135°), B->A(180°)]，
## 反向边 B->A 位于下标 1，其前一条是 B->C —— 正是沿面走向的下一条边。
static func _trace_face(graph: Dictionary, a: Vector2, b: Vector2, p: Vector2) -> PackedVector2Array:
	var left := Vector2(-(b - a).y, (b - a).x)
	var on_left := (p - a).dot(left) > 0.0
	var u := a if on_left else b
	var v := b if on_left else a

	var poly := PackedVector2Array()
	var first_u := u
	var first_v := v
	var guard := 0
	while guard < 100000:
		guard += 1
		poly.append(u)
		var ku := _vkey(u)
		var kv := _vkey(v)
		if not graph.has(kv):
			return PackedVector2Array()
		var outs: Array = graph[kv]
		var idx := -1
		for i in range(outs.size()):
			if String(outs[i][0]) == ku:
				idx = i
				break
		if idx < 0:
			return PackedVector2Array()
		var nxt: Array = outs[(idx - 1 + outs.size()) % outs.size()]
		u = v
		v = nxt[1]
		if _vkey(u) == _vkey(first_u) and _vkey(v) == _vkey(first_v):
			return poly if poly.size() >= 3 else PackedVector2Array()
	return PackedVector2Array()


# ---------------------------------------------------------------------------
# 4) 向内偏移到墙体内表面
# ---------------------------------------------------------------------------

## 每条边按各自所属墙体的半墙厚向内偏移，相邻偏移线的交点即为新顶点。
## 追踪出的面是逆时针的（面在每条有向边的左侧），因此"向内"就是左法向。
static func _inset_to_wall_faces(poly: PackedVector2Array, edges: Array) -> PackedVector2Array:
	var n := poly.size()
	if n < 3:
		return poly
	var halves := PackedFloat64Array()
	halves.resize(n)
	for i in range(n):
		halves[i] = _half_thickness_of(poly[i], poly[(i + 1) % n], edges)
	var off_lines: Array = []
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var d := b - a
		if d.length() <= Tol.MIN_LEN:
			continue
		var u := d.normalized()
		var nrm := Vector2(-u.y, u.x) * halves[i]
		off_lines.append([a + nrm, b + nrm])
	var m := off_lines.size()
	if m < 3:
		return poly
	var out := PackedVector2Array()
	for i in range(m):
		var prev: Array = off_lines[(i - 1 + m) % m]
		var cur: Array = off_lines[i]
		var p1: Vector2 = prev[0]
		var d1: Vector2 = (prev[1] as Vector2) - p1
		var p2: Vector2 = cur[0]
		var d2: Vector2 = (cur[1] as Vector2) - p2
		var den := d1.cross(d2)
		if absf(den) <= 1.0e-9:
			out.append(p2)
			continue
		var t := (p2 - p1).cross(d2) / den
		out.append(p1 + d1 * t)
	return out


## 取某条边处的半墙厚。找不到匹配中心线时退回 0（不判负）。
static func _half_thickness_at(a: Vector2, b: Vector2, edges: Array) -> float:
	return _half_thickness_of(a, b, edges)


## 找与给定边重合的那条中心线边，取其半墙厚。
## 必须校验方向一致，否则会取到穿过同一点但方向垂直的另一条边。
static func _half_thickness_of(a: Vector2, b: Vector2, edges: Array) -> float:
	var best := 0.0
	var best_d := INF
	var mid := (a + b) * 0.5
	var d1 := (b - a)
	if d1.length() <= Tol.MIN_LEN:
		return 0.0
	d1 = d1.normalized()
	for e in edges:
		var ea: Vector2 = e[0]
		var eb: Vector2 = e[1]
		var d2 := eb - ea
		if d2.length() <= Tol.MIN_LEN:
			continue
		d2 = d2.normalized()
		if absf(absf(d1.dot(d2)) - 1.0) > 1.0e-4:
			continue
		var d := mid.distance_to((ea + eb) * 0.5)
		if d < best_d - 1.0e-9:
			best_d = d
			best = float(e[2])
	return best
