class_name SnapEngine
extends RefCounted
## 对象捕捉、栅格捕捉、正交与极轴追踪。
##
## 优先级（与 AutoCAD 一致）：
##   1. 对象捕捉（osnap）—— 精确命中的几何特征点，最高优先级
##   2. 对象捕捉追踪 / 极轴追踪 —— 有参考点时的方向约束
##   3. 正交（F8）—— 约束到 0/90/180/270
##   4. 栅格捕捉 —— 吸附到栅格交点
##   5. 无约束 —— 直接用光标位置
##
## 之所以让对象捕捉压过正交：画墙时若光标恰好落在轴线端点上，
## 用户期望的是那个精确端点，而不是被正交拉偏的点。

## 单个捕捉符号的屏幕尺寸
const MARKER_PX := 6.0
## 追踪虚线的长度（屏幕像素）
const TRACK_EXTEND_PX := 240.0

## 是否启用对象捕捉总开关
var osnap_enabled := true
## 各捕捉类型的启用位掩码。默认打开工程制图最常用的几种。
var osnap_mask := (1 << SnapType.ENDPOINT) | (1 << SnapType.MIDPOINT) \
	| (1 << SnapType.CENTER) | (1 << SnapType.QUADRANT) \
	| (1 << SnapType.INTERSECTION) | (1 << SnapType.PERPENDICULAR) \
	| (1 << SnapType.TANGENT) | (1 << SnapType.NODE) \
	| (1 << SnapType.INSERTION) | (1 << SnapType.NEAREST)

## 栅格捕捉（F9）
var grid_snap := false
var grid_step := 100.0
## 正交（F8）
var ortho := false
## 极轴追踪（F10）
var polar_enabled := false
var polar_step_deg := 15.0
## 捕捉靶框（屏幕像素）
var aperture_px := 12.0

# --- 对象捕捉追踪（F11）---
## 是否启用对象捕捉追踪
var tracking_enabled := true
## 追踪基准点（命令过程中"获取"到的点）。从每个基准引出水平与竖直对齐轴。
var track_points: PackedVector2Array = PackedVector2Array()
## 最多保留的追踪基准数。超过后丢弃最早的 —— 太多基准线会让图面无法读。
const MAX_TRACK_POINTS := 4
## 悬停多久（毫秒）把该捕捉点记为追踪基准
var acquire_linger_ms := 350

## 悬停检测的内部状态
var _hover_point := Vector2.ZERO
var _hover_start_ms := 0
var _hover_active := false
## 最多考察多少条候选曲线做交点与垂足计算
const MAX_CANDIDATES := 24


## 捕捉结果
class Result:
	extends RefCounted
	var hit := false
	var point := Vector2.ZERO
	var type := SnapType.NONE
	## 用于界面显示的提示，如 "端点"、"交点"
	var label := ""
	## 追踪起点（对象捕捉追踪用），无则为 sentinel
	var track_from := Vector2.ZERO
	var has_track := false
	## 参与捕捉的那个图元（用于"延长线"等需要原曲线的捕捉）
	var entity: CadEntity = null
	## 本次用到的追踪对齐轴，供界面画虚线。
	## 每项为 [is_vertical: bool, fixed_value: float, base: Vector2]
	var track_axes: Array = []
	## 是否为两条追踪轴的交点（交点比单轴更强）
	var is_track_cross := false

	func describe() -> String:
		if not hit:
			return ""
		return label


func is_type_enabled(t: int) -> bool:
	return (osnap_mask & (1 << t)) != 0


func set_type_enabled(t: int, on: bool) -> void:
	if on:
		osnap_mask |= (1 << t)
	else:
		osnap_mask &= ~(1 << t)


## 主入口。
##   cursor   当前光标位置（模型坐标）
##   view     视图变换，用于把屏幕靶框换算成模型容差
##   from     橡皮筋起点（垂足/切点/追踪需要），无则传 none
## 返回 Result。
func resolve(doc: CadDocument, index: SpatialIndex, view: ViewTransform,
		cursor: Vector2, from: Variant = null) -> Result:
	var r := Result.new()
	var has_from := from != null
	var from_p: Vector2 = from if has_from else Vector2.ZERO

	# 1) 对象捕捉
	if osnap_enabled:
		var o := _object_snap(doc, index, view, cursor, from_p if has_from else null)
		if o.hit:
			return o

	# 2) 对象捕捉追踪。优先级高于极轴与正交 ——
	#    追踪用的是用户"确认过"的基准点，比方向约束更精确。
	if tracking_enabled and not track_points.is_empty():
		var t := _resolve_tracking(view, cursor)
		if t.hit:
			return t

	# 3) 极轴追踪（有基点时优先于正交）
	if polar_enabled and has_from:
		var p := _polar(cursor, from_p)
		if p.hit:
			return p

	# 4) 正交
	if ortho and has_from:
		r.hit = true
		r.point = _ortho_project(cursor, from_p)
		r.type = SnapType.POLAR
		r.label = "正交"
		r.track_from = from_p
		r.has_track = true
		return r

	# 5) 栅格捕捉
	if grid_snap and grid_step > 0.0:
		r.hit = true
		r.point = Vector2(
			roundf(cursor.x / grid_step) * grid_step,
			roundf(cursor.y / grid_step) * grid_step)
		r.type = SnapType.GRID
		r.label = "栅格"
		return r

	r.point = cursor
	return r


# ---------------------------------------------------------------------------
# 对象捕捉
# ---------------------------------------------------------------------------

func _object_snap(doc: CadDocument, index: SpatialIndex, view: ViewTransform,
		cursor: Vector2, from) -> Result:
	var tol := view.tolerance_for_pixels(aperture_px)
	var best := Result.new()
	var best_type := 999
	var best_d := INF

	# 收集光标附近的图元
	var cands: Array[CadEntity] = []
	if index != null:
		cands = index.query_rect(Rect2(cursor - Vector2(tol, tol), Vector2(tol, tol) * 2.0))
	else:
		for e in doc.entities:
			if e.get_bbox().grow(tol).has_point(cursor):
				cands.append(e)
	if cands.size() > MAX_CANDIDATES:
		cands.resize(MAX_CANDIDATES)

	# 先统一过滤掉不可见图层与隐藏图元，后续所有循环都基于这份干净候选集。
	# 若只在收集曲线时过滤，特征点循环会漏掉图层判断，隐藏图层仍可被捕捉。
	var visible_cands: Array[CadEntity] = []
	for e in cands:
		if not e.visible:
			continue
		var l := doc.get_layer(e.layer)
		if l != null and not l.is_displayable():
			continue
		visible_cands.append(e)

	var curves: Array[GeoCurve] = []
	for e in visible_cands:
		for c in CurveOps.decompose_all(e):
			curves.append(c)

	# 逐个图元的特征点（端点/中点/圆心/象限点/节点/插入点）
	for e in visible_cands:
		for f in e.feature_points():
			var t := int(f["type"])
			if not is_type_enabled(t):
				continue
			var p: Vector2 = f["point"]
			var d := p.distance_to(cursor)
			if d > tol:
				continue
			if _better(t, d, best_type, best_d):
				best = _make(p, t, e)
				best_type = t
				best_d = d

	# 交点与外观交点（需要两两求交）
	if is_type_enabled(SnapType.INTERSECTION):
		var n := curves.size()
		for i in range(n):
			for j in range(i + 1, n):
				for p in CurveOps.intersect_curves(curves[i], curves[j]):
					var d := p.distance_to(cursor)
					if d <= tol and _better(SnapType.INTERSECTION, d, best_type, best_d):
						best = _make(p, SnapType.INTERSECTION, null)
						best_type = SnapType.INTERSECTION
						best_d = d

	# 垂足与切点（需要基点）
	if from != null:
		if is_type_enabled(SnapType.PERPENDICULAR):
			for c in curves:
				# _perpendicular_foot 可能返回 null，不能用 := 推断类型
				var q = _perpendicular_foot(c, from)
				if q == null:
					continue
				var d: float = (q as Vector2).distance_to(cursor)
				if d <= tol and _better(SnapType.PERPENDICULAR, d, best_type, best_d):
					best = _make(q, SnapType.PERPENDICULAR, null)
					best_type = SnapType.PERPENDICULAR
					best_d = d
		if is_type_enabled(SnapType.TANGENT):
			for c in curves:
				for q in _tangent_points(c, from):
					var d := q.distance_to(cursor)
					if d <= tol and _better(SnapType.TANGENT, d, best_type, best_d):
						best = _make(q, SnapType.TANGENT, null)
						best_type = SnapType.TANGENT
						best_d = d

	# 最近点（优先级最低，作为兜底）
	if is_type_enabled(SnapType.NEAREST) and best_type > SnapType.NEAREST:
		for c in curves:
			var r := c.closest_point(cursor)
			var d: float = r["dist"]
			if d <= tol and _better(SnapType.NEAREST, d, best_type, best_d):
				best = _make(r["point"], SnapType.NEAREST, null)
				best_type = SnapType.NEAREST
				best_d = d

	if best.hit and from != null:
		# 供对象捕捉追踪使用：记录基点
		best.track_from = from
		best.has_track = true
	return best


## 优先级裁决：类型序号小的优先；同类型则取更近的。
## 注意距离要显式传入（best_d），不能从 best.point 反推 —— 那是在拿点跟自己比。
func _better(t: int, d: float, best_type: int, best_d: float) -> bool:
	if t < best_type:
		return true
	if t > best_type:
		return false
	return d < best_d


func _make(p: Vector2, t: int, e: CadEntity) -> Result:
	var r := Result.new()
	r.hit = true
	r.point = p
	r.type = t
	r.label = SnapType.name_of(t)
	r.entity = e
	return r


## 点到曲线的垂足（曲线上的最近点即为垂足，因为垂足定义就是切向垂直于连线）
func _perpendicular_foot(c: GeoCurve, from: Vector2) -> Variant:
	var r := c.closest_point(from)
	return r["point"]


## 自 from 点向圆/圆弧作切线的切点。
## 判定：切点 P 满足 (P - center) · (from - P) = 0，即切线与半径垂直。
func _tangent_points(c: GeoCurve, from: Vector2) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var center: Vector2
	var radius: float
	if c.kind() == GeoCurve.Kind.ARC:
		var a := c as GeoArc
		center = a.center
		radius = a.radius
	elif c.kind() == GeoCurve.Kind.POLY:
		for sp in (c as GeoPoly).spans():
			for q in _tangent_points(sp, from):
				out.append(q)
		return out
	else:
		return out
	var d := center.distance_to(from)
	if d <= radius + Tol.MIN_LEN:
		return out  # 点在圆内，无切线
	var base := from - center
	var a_len := radius * radius / d
	var h := radius * sqrt(maxf(d * d - radius * radius, 0.0)) / d
	var dir := base / d
	var perp := Vector2(-dir.y, dir.x)
	for s in PackedFloat64Array([1.0, -1.0]):
		var p := center + dir * a_len + perp * (h * s)
		# 圆弧要确认切点确实落在弧段上；整圆无需判断
		if c.kind() != GeoCurve.Kind.ARC or (c as GeoArc).contains_point(p):
			out.append(p)
	return out


# ---------------------------------------------------------------------------
# 对象捕捉追踪
# ---------------------------------------------------------------------------

## 从已获取的基准点引出水平与竖直对齐轴，光标靠近时吸附。
##
## 只吸附被命中的那一个坐标：竖直轴固定 x、水平轴固定 y。
## 两条轴同时命中时取交点 —— 这正是 OST 最有用的用法
## （例如过 A 点的竖直线与过 B 点的水平线交点）。
func _resolve_tracking(view: ViewTransform, cursor: Vector2) -> Result:
	var tol := view.tolerance_for_pixels(aperture_px)
	var best_dx := INF
	var best_dy := INF
	var tx := 0.0
	var ty := 0.0
	var base_x := Vector2.ZERO
	var base_y := Vector2.ZERO
	for bp in track_points:
		var dx := absf(cursor.x - bp.x)
		if dx <= tol and dx < best_dx:
			best_dx = dx
			tx = bp.x
			base_x = bp
		var dy := absf(cursor.y - bp.y)
		if dy <= tol and dy < best_dy:
			best_dy = dy
			ty = bp.y
			base_y = bp
	var has_x := best_dx < INF
	var has_y := best_dy < INF
	if not has_x and not has_y:
		return Result.new()

	var r := Result.new()
	r.hit = true
	r.point = Vector2(tx if has_x else cursor.x, ty if has_y else cursor.y)
	r.type = SnapType.TRACK
	r.is_track_cross = has_x and has_y
	r.label = "追踪交点" if r.is_track_cross else "追踪"
	if has_x:
		r.track_axes.append([true, tx, base_x])
	if has_y:
		r.track_axes.append([false, ty, base_y])
	r.has_track = true
	r.track_from = r.point
	return r


## 悬停获取：光标停在同一个捕捉点上超过 acquire_linger_ms 毫秒，
## 就把该点记为追踪基准。返回本次是否新获取了一个点。
##
## 之所以要"悬停"而不是"一碰就记"：否则光标扫过图面时会不断误收集基准点，
## 对齐线越积越多，反而没法用。
func update_hover(r: Result, now_ms: int) -> bool:
	if not tracking_enabled:
		_hover_active = false
		return false
	if r == null or not r.hit:
		_hover_active = false
		return false
	# 只对真正的几何捕捉点做获取，追踪结果本身不再作为新基准
	if r.type == SnapType.TRACK or r.type == SnapType.NEAREST \
			or r.type == SnapType.GRID or r.type == SnapType.POLAR:
		_hover_active = false
		return false
	if not _hover_active or _hover_point.distance_to(r.point) > Tol.DIST:
		_hover_active = true
		_hover_point = r.point
		_hover_start_ms = now_ms
		return false
	if now_ms - _hover_start_ms < acquire_linger_ms:
		return false
	_hover_active = false
	return acquire(r.point)


## 记一个追踪基准点。已存在相近点时只更新时间不重复添加。
func acquire(p: Vector2) -> bool:
	for bp in track_points:
		if bp.distance_to(p) <= Tol.DIST:
			return false
	track_points.append(p)
	while track_points.size() > MAX_TRACK_POINTS:
		track_points.remove_at(0)
	return true


func clear_tracking() -> void:
	track_points.clear()
	_hover_active = false


# ---------------------------------------------------------------------------
# 正交与极轴
# ---------------------------------------------------------------------------

## 把光标投影到距离基点最近的正交方向上
func _ortho_project(cursor: Vector2, from: Vector2) -> Vector2:
	var d := cursor - from
	if absf(d.x) >= absf(d.y):
		return Vector2(cursor.x, from.y)
	return Vector2(from.x, cursor.y)


## 极轴追踪：把光标方向吸附到 step 度的整数倍上，并保留光标到基点的距离
func _polar(cursor: Vector2, from: Vector2) -> Result:
	var r := Result.new()
	var d := cursor - from
	var dist := d.length()
	if dist <= Tol.MIN_LEN:
		r.point = cursor
		return r
	var step := deg_to_rad(maxf(polar_step_deg, 1.0))
	var ang := roundf(d.angle() / step) * step
	r.hit = true
	r.point = from + Vector2(cos(ang), sin(ang)) * dist
	r.type = SnapType.POLAR
	r.label = "极轴 %.0f°" % rad_to_deg(ang)
	r.track_from = from
	r.has_track = true
	return r


# ---------------------------------------------------------------------------
# 追踪轴的绘制
# ---------------------------------------------------------------------------

## 绘制追踪对齐轴：从每个基准点引出贯穿视口的水平与竖直虚线。
## active 为当前捕捉结果，其中被命中的轴用亮色突出，并画出对齐用的十字。
##
## 只画贯穿视口的整条线（而不是一小段）是有意的：
## OST 的用途就是"沿这条线找位置"，线短了反而看不出对齐到哪。
func draw_tracking(ci: CanvasItem, view: ViewTransform, active: Result = null) -> void:
	if not tracking_enabled or track_points.is_empty():
		return
	var vr := view.visible_rect()
	var dim := Color(0.55, 0.75, 0.95, 0.45)
	var hot := Color(1.0, 0.75, 0.35, 0.9)
	# 记下被命中的轴，便于比对
	var hot_v: Array[float] = []
	var hot_h: Array[float] = []
	if active != null and active.hit and active.type == SnapType.TRACK:
		for ax in active.track_axes:
			var rec: Array = ax
			if bool(rec[0]):
				hot_v.append(float(rec[1]))
			else:
				hot_h.append(float(rec[1]))

	for bp in track_points:
		# 竖直轴
		var is_hot_v := _has_close(hot_v, bp.x)
		_dashed(ci, view.to_screen(Vector2(bp.x, vr.position.y)),
			view.to_screen(Vector2(bp.x, vr.position.y + vr.size.y)), hot if is_hot_v else dim)
		# 水平轴
		var is_hot_h := _has_close(hot_h, bp.y)
		_dashed(ci, view.to_screen(Vector2(vr.position.x, bp.y)),
			view.to_screen(Vector2(vr.position.x + vr.size.x, bp.y)), hot if is_hot_h else dim)
		# 基准点本身画一个小方块，提示它是被"获取"过的
		var sp := view.to_screen(bp)
		ci.draw_rect(Rect2(sp - Vector2(3, 3), Vector2(6, 6)), Color(1.0, 0.85, 0.25, 0.9), false, 1.2)

	# 命中的轴再叠一个十字，与捕捉点区分开
	if active != null and active.hit and active.type == SnapType.TRACK:
		var p := view.to_screen(active.point)
		ci.draw_line(p - Vector2(11, 0), p + Vector2(11, 0), hot, 1.6, true)
		ci.draw_line(p - Vector2(0, 11), p + Vector2(0, 11), hot, 1.6, true)


static func _has_close(arr: Array[float], v: float) -> bool:
	for a in arr:
		if absf(a - v) <= Tol.DIST:
			return true
	return false


# ---------------------------------------------------------------------------
# 捕捉标记绘制
# ---------------------------------------------------------------------------

## 在屏幕上绘制捕捉标记。position 为屏幕坐标。
func draw_marker(ci: CanvasItem, screen_pos: Vector2, r: Result,
		font: Font = null, tracking_origin: Variant = null, is_tracking := false) -> void:
	if not r.hit or r.type == SnapType.NONE:
		return
	var s := MARKER_PX
	var col := Color(1.0, 0.85, 0.25, 0.95)
	var p := screen_pos
	match r.type:
		SnapType.ENDPOINT:
			# 方框
			ci.draw_rect(Rect2(p - Vector2(s, s), Vector2(s, s) * 2.0), col, false, 1.6)
		SnapType.MIDPOINT:
			# 三角形
			var t := PackedVector2Array([p + Vector2(0, -s * 1.2), p + Vector2(-s * 1.1, s * 0.8), p + Vector2(s * 1.1, s * 0.8)])
			ci.draw_polyline(PackedVector2Array([t[0], t[1], t[2], t[0]]), col, 1.6, true)
		SnapType.CENTER:
			ci.draw_arc(p, s, 0.0, TAU, 20, col, 1.6, true)
		SnapType.QUADRANT:
			var q := PackedVector2Array([p + Vector2(0, -s), p + Vector2(s, 0), p + Vector2(0, s), p + Vector2(-s, 0), p + Vector2(0, -s)])
			ci.draw_polyline(q, col, 1.6, true)
		SnapType.INTERSECTION, SnapType.APPARENT_INTERSECT:
			ci.draw_line(p - Vector2(s, s), p + Vector2(s, s), col, 1.6, true)
			ci.draw_line(p - Vector2(s, -s), p + Vector2(s, -s), col, 1.6, true)
		SnapType.PERPENDICULAR:
			# 直角符号
			ci.draw_line(p + Vector2(-s, s), p + Vector2(s, s), col, 1.6, true)
			ci.draw_line(p + Vector2(s, s), p + Vector2(s, -s), col, 1.6, true)
			ci.draw_line(p + Vector2(-s, 0), p + Vector2(-s, s), col, 1.2, true)
			ci.draw_line(p + Vector2(0, -s), p + Vector2(s, -s), col, 1.2, true)
		SnapType.TANGENT:
			ci.draw_arc(p, s, 0.0, TAU, 20, col, 1.4, true)
			ci.draw_line(p + Vector2(-s, -s), p + Vector2(s, -s), col, 1.4, true)
		SnapType.NODE:
			ci.draw_arc(p, s * 0.9, 0.0, TAU, 20, col, 1.4, true)
			ci.draw_line(p - Vector2(s * 1.4, 0), p + Vector2(s * 1.4, 0), col, 1.4, true)
			ci.draw_line(p - Vector2(0, s * 1.4), p + Vector2(0, s * 1.4), col, 1.4, true)
		SnapType.INSERTION:
			ci.draw_rect(Rect2(p - Vector2(s, s), Vector2(s, s) * 2.0), col, false, 1.4)
			ci.draw_line(p - Vector2(s * 1.5, 0), p + Vector2(s * 1.5, 0), col, 1.2, true)
			ci.draw_line(p - Vector2(0, s * 1.5), p + Vector2(0, s * 1.5), col, 1.2, true)
		SnapType.TRACK:
			# 追踪：十字已在 draw_tracking 里画过，这里只补文字提示
			pass
		SnapType.NEAREST:
			# 沙漏形
			var h := PackedVector2Array([
				p + Vector2(-s, -s), p + Vector2(s, -s), p + Vector2(-s, s),
				p + Vector2(s, s), p + Vector2(-s, -s)])
			ci.draw_polyline(h, col, 1.4, true)
		_:
			ci.draw_rect(Rect2(p - Vector2(s, s), Vector2(s, s) * 2.0), col, false, 1.4)

	# 对象捕捉追踪：自基点向捕捉点引一条虚线，提示当前受哪个基点约束
	if is_tracking and r.has_track and tracking_origin != null:
		_dashed(ci, tracking_origin, screen_pos, Color(0.6, 0.85, 1.0, 0.65))
	# 文字提示
	var f := font if font != null else ThemeDB.fallback_font
	ci.draw_string(f, p + Vector2(s + 6.0, -s - 4.0), r.label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.9, 0.5))


func _dashed(ci: CanvasItem, a: Vector2, b: Vector2, col: Color) -> void:
	var total := a.distance_to(b)
	if total <= 0.5:
		return
	var dir := (b - a) / total
	var pos := 0.0
	var on := true
	while pos < total:
		var step := minf(6.0, total - pos)
		if on:
			ci.draw_line(a + dir * pos, a + dir * (pos + step), col, 1.0, false)
		pos += step
		on = not on
