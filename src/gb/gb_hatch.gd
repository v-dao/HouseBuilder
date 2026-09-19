class_name GbHatch
extends RefCounted
## 常用建筑材料图例库（GB/T 50001—2017 附录 A）。
##
## 设计：把每种图例表达为若干"可无限平铺的基元层"。
## 这样二十多种国标图例只需五种基元（线、点、圆、三角、波浪）的组合即可覆盖，
## 新增图例是加一行数据，不需要写新代码。
##
## 尺寸单位：**图纸毫米**。生成时按出图比例换算到模型空间，
## 这样同一图例在 1:50 和 1:100 的图上打印出来一样大。

## 平铺基元
enum Prim {
	LINE,      ## 平行线族（可指定角度、间距、虚实）
	DOT,       ## 点阵
	CIRCLE,    ## 圆（卵石、陶粒、多孔材料）
	TRIANGLE,  ## 小三角（焦渣、混凝土骨料）
	WAVE,      ## 波浪线（液体、纤维、木纹）
}


## 图例的一个基元层
class Layer:
	extends RefCounted
	var prim: int = Prim.LINE
	## 线族方向（度）；点阵/圆阵按此角度排布
	var angle_deg: float = 45.0
	## 间距（图纸 mm）
	var spacing: float = 2.0
	## 基元尺寸（图纸 mm）：点/圆/三角的尺寸
	var size: float = 1.0
	## 相位偏移（图纸 mm），用于错开重叠层
	var offset: Vector2 = Vector2.ZERO
	## 线的虚实（图纸 mm，正画负空）；空为实线
	var dash: PackedFloat64Array = PackedFloat64Array()
	## 线宽（图纸 mm）
	var weight: float = 0.18

	func _init(p_prim: int, p_angle: float, p_spacing: float, p_size := 1.0,
			p_offset := Vector2.ZERO, p_dash := PackedFloat64Array(), p_weight := 0.18) -> void:
		prim = p_prim
		angle_deg = p_angle
		spacing = p_spacing
		size = p_size
		offset = p_offset
		dash = p_dash
		weight = p_weight


static func _l(angle: float, spacing: float, size := 1.0, offset := Vector2.ZERO,
		dash := PackedFloat64Array(), weight := 0.18) -> Layer:
	return Layer.new(Prim.LINE, angle, spacing, size, offset, dash, weight)


static func _d(spacing: float, size := 0.6, angle := 0.0) -> Layer:
	return Layer.new(Prim.DOT, angle, spacing, size)


static func _c(spacing: float, size: float, angle := 0.0) -> Layer:
	return Layer.new(Prim.CIRCLE, angle, spacing, size)


static func _t(spacing: float, size := 1.2, angle := 0.0) -> Layer:
	return Layer.new(Prim.TRIANGLE, angle, spacing, size)


static func _w(angle: float, spacing: float, size := 0.8) -> Layer:
	return Layer.new(Prim.WAVE, angle, spacing, size)


# ---------------------------------------------------------------------------
# 图例库
# ---------------------------------------------------------------------------

static var _lib: Dictionary = {}


## 返回 名称 -> Array[Layer]。首次调用时构建并缓存。
static func library() -> Dictionary:
	if not _lib.is_empty():
		return _lib
	var m := {}

	# --- 土壤类 ---
	m["自然土壤"] = [_l(45.0, 3.0), _d(6.0, 0.5)]
	m["夯实土壤"] = [_l(45.0, 3.0), _l(-45.0, 3.0)]
	m["素土"] = [_l(45.0, 3.5)]
	m["灰土"] = [_l(45.0, 3.0), _d(5.0, 0.5)]
	m["砂"] = [_d(2.2, 0.55)]
	m["砂砾石"] = [_d(3.0, 0.5), _c(7.0, 1.4)]
	m["焦渣"] = [_t(6.0, 1.4), _d(6.0, 0.5)]

	# --- 石材与块材 ---
	m["天然石材"] = [_l(45.0, 4.0), _l(-45.0, 4.0)]
	m["毛石"] = [_c(8.0, 3.4)]
	m["卵石"] = [_c(6.0, 2.4)]
	m["普通砖"] = [_l(45.0, 3.5)]
	m["耐火砖"] = [_l(45.0, 3.5), _d(7.0, 0.5)]
	m["饰面砖"] = [_l(0.0, 5.0), _l(90.0, 5.0)]
	m["陶粒"] = [_c(5.0, 1.9)]

	# --- 混凝土类 ---
	m["混凝土"] = [_d(2.8, 0.55), _t(8.0, 1.3)]
	m["钢筋混凝土"] = [_l(45.0, 4.0), _d(4.0, 0.6)]
	m["多孔材料"] = [_c(4.0, 1.1)]
	m["轻质填充墙"] = [_l(45.0, 4.0), _l(-45.0, 4.0)]

	# --- 木材类 ---
	m["木材_横纹"] = [_w(0.0, 5.0, 1.4)]
	m["木材_纵纹"] = [_l(0.0, 2.0)]
	m["胶合板"] = [_l(0.0, 2.5), _w(0.0, 10.0, 0.9)]

	# --- 金属与非金属 ---
	m["金属"] = [_l(45.0, 2.0, 1.0, Vector2.ZERO, PackedFloat64Array(), 0.2)]
	m["网状材料"] = [_l(45.0, 2.8), _l(-45.0, 2.8)]
	m["玻璃"] = [_l(45.0, 6.0)]
	m["橡胶"] = [_l(45.0, 2.0), _l(-45.0, 2.0)]
	m["塑料"] = [_l(45.0, 1.5)]
	m["防水材料"] = [_l(0.0, 3.0, 1.0, Vector2.ZERO, PackedFloat64Array([2.0, -1.0]))]
	m["液体"] = [_w(0.0, 4.0, 1.0)]

	# --- 保温与粉刷 ---
	m["松散保温材料"] = [_d(4.5, 0.6), _c(9.0, 1.7)]
	m["板状保温材料"] = [_l(45.0, 5.0), _l(-45.0, 5.0), _d(8.0, 0.5)]
	m["纤维材料"] = [_w(0.0, 3.0, 0.8)]
	m["粉刷"] = [_d(2.0, 0.5)]
	m["石膏板"] = [_d(2.5, 0.5)]

	# --- 常用简化图例 ---
	m["实心"] = []          # 由实心填充处理，见 EntHatch.solid
	m["通用斜线"] = [_l(45.0, 3.0)]

	_lib = m
	return _lib


static func pattern_names() -> Array[String]:
	var out: Array[String] = []
	for k in library().keys():
		out.append(String(k))
	out.sort()
	return out


static func layers_of(name: String) -> Array:
	return library().get(name, [])


# ===========================================================================
# 图案生成
# ===========================================================================

## 生成填充线段。返回扁平的端点对数组（供 draw_multiline 直接使用）。
##
## boundary 为世界坐标下的闭合轮廓；scale 为出图比例；
## pattern_scale 为用户额外给的图案比例；angle_delta_deg 为附加旋转。
static func generate(boundary: PackedVector2Array, layers: Array, scale: float,
		pattern_scale := 1.0, angle_delta_deg := 0.0, origin := Vector2.ZERO) -> PackedVector2Array:
	var out := PackedVector2Array()
	if boundary.size() < 3 or layers.is_empty():
		return out
	var poly := _prepare(boundary)
	if poly.size() < 3:
		return out

	var bb := _bbox(poly)
	var diag := bb.size.length()
	var k := maxf(scale * pattern_scale, 1.0e-6)

	for layer in layers:
		var L: Layer = layer
		var ang := deg_to_rad(L.angle_deg + angle_delta_deg)
		var sp := maxf(L.spacing * k, 1.0e-6)
		# 相位：图案原点决定线的起始位置，使多段填充能对齐
		var base := origin if origin != Vector2.ZERO else bb.position
		var phase := L.offset * k
		match L.prim:
			Prim.LINE:
				_emit_lines(out, poly, bb, diag, ang, sp, L, k, base, phase)
			Prim.WAVE:
				_emit_waves(out, poly, bb, diag, ang, sp, L, k, base, phase)
			Prim.DOT:
				_emit_dots(out, poly, bb, ang, sp, L, k, base, phase, false)
			Prim.CIRCLE:
				_emit_dots(out, poly, bb, ang, sp, L, k, base, phase, true)
			Prim.TRIANGLE:
				_emit_triangles(out, poly, bb, ang, sp, L, k, base, phase)
	return out


## 平行线族：沿法向按间距铺线，逐条裁剪到轮廓内
static func _emit_lines(out: PackedVector2Array, poly: PackedVector2Array, bb: Rect2,
		diag: float, ang: float, sp: float, L: Layer, k: float,
		base: Vector2, phase: Vector2) -> void:
	var dir := Vector2(cos(ang), sin(ang))
	var nrm := Vector2(-dir.y, dir.x)
	# 以 base（图案原点）为基准向两侧铺线，保证同一次填充内图案相位一致
	var half := int(ceil(diag / sp)) + 2
	var dash := _scaled_dash(L.dash, k)
	for i in range(-half, half + 1):
		var o := nrm * (float(i) * sp) + nrm * phase.dot(nrm) + dir * phase.dot(dir)
		var base_pt := base + o
		var a := base_pt - dir * diag
		var b := base_pt + dir * diag
		for seg in _clip_segment(a, b, poly):
			if dash.is_empty():
				out.append(seg[0])
				out.append(seg[1])
			else:
				_emit_dashed(out, seg[0], seg[1], dash)


## 波浪线族：沿一条基准线作正弦波，再裁剪
static func _emit_waves(out: PackedVector2Array, poly: PackedVector2Array, bb: Rect2,
		diag: float, ang: float, sp: float, L: Layer, k: float,
		base: Vector2, phase: Vector2) -> void:
	var dir := Vector2(cos(ang), sin(ang))
	var nrm := Vector2(-dir.y, dir.x)
	var amp := maxf(L.size * k, 1.0e-6)
	var wave_len := maxf(sp * 4.0, amp * 12.0)
	var half := int(ceil(diag / sp)) + 2
	var steps := int(clampf(diag / maxf(wave_len * 0.1, 1.0e-6), 24.0, 600.0))
	for i in range(-half, half + 1):
		var base_pt := base + nrm * (float(i) * sp + phase.dot(nrm))
		var pts := PackedVector2Array()
		for j in range(steps + 1):
			var t := float(j) / float(steps)
			var d := (t - 0.5) * diag * 2.0
			var w := sin(d / wave_len * TAU) * amp
			pts.append(base_pt + dir * d + nrm * w)
		# 折线逐段裁剪
		for j in range(pts.size() - 1):
			for seg in _clip_segment(pts[j], pts[j + 1], poly):
				out.append(seg[0])
				out.append(seg[1])


## 点阵 / 圆阵
static func _emit_dots(out: PackedVector2Array, poly: PackedVector2Array, bb: Rect2,
		ang: float, sp: float, L: Layer, k: float, base: Vector2, phase: Vector2,
		as_circle: bool) -> void:
	var dir := Vector2(cos(ang), sin(ang))
	var nrm := Vector2(-dir.y, dir.x)
	var size := maxf(L.size * k, 1.0e-6)
	var rows := int(ceil(bb.size.y / sp)) + 2
	var cols := int(ceil(bb.size.x / sp)) + 2
	var mid := bb.position + bb.size * 0.5
	for r in range(-rows, rows + 1):
		for c in range(-cols, cols + 1):
			var p := mid + dir * (float(c) * sp) + nrm * (float(r) * sp)
			if not _fully_inside(p, size, poly):
				continue
			if as_circle:
				_emit_circle(out, p, size * 0.5)
			else:
				# 点用极短十字表示，屏幕上仍可辨
				var r2 := size * 0.5
				out.append(p - Vector2(r2, 0))
				out.append(p + Vector2(r2, 0))
				out.append(p - Vector2(0, r2))
				out.append(p + Vector2(0, r2))


## 小三角阵（焦渣、混凝土骨料）
static func _emit_triangles(out: PackedVector2Array, poly: PackedVector2Array, bb: Rect2,
		ang: float, sp: float, L: Layer, k: float, base: Vector2, phase: Vector2) -> void:
	var dir := Vector2(cos(ang), sin(ang))
	var nrm := Vector2(-dir.y, dir.x)
	var size := maxf(L.size * k, 1.0e-6)
	var rows := int(ceil(bb.size.y / sp)) + 2
	var cols := int(ceil(bb.size.x / sp)) + 2
	var mid := bb.position + bb.size * 0.5
	# 交错排布，避免整齐得像网格
	for r in range(-rows, rows + 1):
		for c in range(-cols, cols + 1):
			var stagger := sp * 0.5 * float(posmod(r, 2))
			var p := mid + dir * (float(c) * sp + stagger) + nrm * (float(r) * sp)
			if not _fully_inside(p, size, poly):
				continue
			var h := size * 0.5
			var a := p + Vector2(-h, -h * 0.577)
			var b := p + Vector2(h, -h * 0.577)
			var cp := p + Vector2(0, h * 1.155)
			out.append(a)
			out.append(b)
			out.append(b)
			out.append(cp)
			out.append(cp)
			out.append(a)


static func _emit_circle(out: PackedVector2Array, c: Vector2, r: float) -> void:
	var n := 16
	var prev := c + Vector2(r, 0)
	for i in range(1, n + 1):
		var a := TAU * float(i) / float(n)
		var q := c + Vector2(cos(a), sin(a)) * r
		out.append(prev)
		out.append(q)
		prev = q


static func _emit_dashed(out: PackedVector2Array, a: Vector2, b: Vector2, dash: PackedFloat64Array) -> void:
	var total := a.distance_to(b)
	if total <= Tol.MIN_LEN:
		return
	var dir := (b - a) / total
	var pos := 0.0
	var i := 0
	var remain := absf(dash[0])
	var draw := dash[0] >= 0.0
	var guard := 0
	while pos < total - 1.0e-9 and guard < 4096:
		guard += 1
		var step := minf(remain, total - pos)
		if draw and step > Tol.MIN_LEN:
			out.append(a + dir * pos)
			out.append(a + dir * (pos + step))
		pos += step
		remain -= step
		if remain <= 1.0e-9:
			i = (i + 1) % dash.size()
			remain = absf(dash[i])
			draw = dash[i] >= 0.0


static func _scaled_dash(dash: PackedFloat64Array, k: float) -> PackedFloat64Array:
	if dash.is_empty():
		return dash
	var out := PackedFloat64Array()
	out.resize(dash.size())
	for i in range(dash.size()):
		out[i] = dash[i] * k
	return out


# ===========================================================================
# 多边形工具
# ===========================================================================

static func _prepare(b: PackedVector2Array) -> PackedVector2Array:
	# 去掉末尾与首点重合的重复点
	var out := b.duplicate()
	while out.size() > 1 and out[0].distance_to(out[out.size() - 1]) <= Tol.POINT:
		out.remove_at(out.size() - 1)
	return out


static func _bbox(p: PackedVector2Array) -> Rect2:
	var mn := p[0]
	var mx := p[0]
	for q in p:
		mn = Vector2(minf(mn.x, q.x), minf(mn.y, q.y))
		mx = Vector2(maxf(mx.x, q.x), maxf(mx.y, q.y))
	return Rect2(mn, mx - mn)


## 射线法判定点是否在多边形内
static func point_in_polygon(pt: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in range(n):
		var a := poly[i]
		var b := poly[j]
		if ((a.y > pt.y) != (b.y > pt.y)):
			var x := (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x
			if pt.x < x:
				inside = not inside
		j = i
	return inside


## 以点为中心、半径 r 的基元是否完整落在多边形内。
## 只判中心会让圆和三角戳出轮廓外，因此额外检查四方与斜向共八个采样点。
static func _fully_inside(p: Vector2, r: float, poly: PackedVector2Array) -> bool:
	if not point_in_polygon(p, poly):
		return false
	if r <= 0.0:
		return true
	var d := r * 0.7071
	var probes := [
		Vector2(r, 0), Vector2(-r, 0), Vector2(0, r), Vector2(0, -r),
		Vector2(d, d), Vector2(-d, d), Vector2(d, -d), Vector2(-d, -d),
	]
	for q in probes:
		if not point_in_polygon(p + q, poly):
			return false
	return true


## 把线段裁剪到多边形内，返回若干 [起点, 终点] 子段。
## 做法：求线段与各边的交点参数，排序后逐段用中点判定内外。
static func _clip_segment(a: Vector2, b: Vector2, poly: PackedVector2Array) -> Array:
	var out: Array = []
	var d := b - a
	var ts: Array[float] = [0.0, 1.0]
	var n := poly.size()
	for i in range(n):
		var p1 := poly[i]
		var p2 := poly[(i + 1) % n]
		var e := p2 - p1
		var den := d.cross(e)
		if absf(den) <= 1.0e-12:
			continue  # 平行
		var t := (p1 - a).cross(e) / den
		var u := (p1 - a).cross(d) / den
		if t > 1.0e-9 and t < 1.0 - 1.0e-9 and u >= -1.0e-9 and u <= 1.0 + 1.0e-9:
			ts.append(clampf(t, 0.0, 1.0))
	ts.sort()
	for i in range(ts.size() - 1):
		var t0 := ts[i]
		var t1 := ts[i + 1]
		if t1 - t0 <= 1.0e-9:
			continue
		var mid := a + d * ((t0 + t1) * 0.5)
		if point_in_polygon(mid, poly):
			out.append([a + d * t0, a + d * t1])
	return out
