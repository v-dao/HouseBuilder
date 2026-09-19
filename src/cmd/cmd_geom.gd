class_name CmdGeom
extends RefCounted
## 几何编辑类命令：偏移、修剪、延伸、打断、圆角、倒角、分解、合并、阵列。
##
## 命名与 AutoCAD 对齐，交互尽量保持一致，降低用户迁移成本。


## 需要点取对象的命令基类（与"先选对象"的编辑命令不同）
class PickBase extends CadCommand:
	func _begin(label: String) -> void:
		ctx.doc.begin_transaction(label)

	func _finish() -> void:
		ctx.doc.commit_transaction()
		ctx.set_status("")

	func _abort() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	## 取容差内的图元（屏幕 8 像素换算到模型单位）
	func _pick(p: Vector2) -> CadEntity:
		var tol := ctx.view.tolerance_for_pixels(8.0)
		return CadSelection.pick(ctx.doc, ctx.index, p, tol)

	func _add(e: CadEntity) -> void:
		apply_defaults(e)
		ctx.doc.add_entity(e)

	func on_mouse_move(_p: Vector2) -> void:
		ctx.request_redraw()


# ===========================================================================
# 偏移
# ===========================================================================

class Offset extends PickBase:
	enum { S_DIST, S_SIDE, S_MORE }
	var _state := S_DIST
	var _dist := 0.0
	var _src: CadEntity = null
	var _pending := PackedVector2Array()

	func cmd_name() -> String:
		return "OFFSET"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["o"])

	func help_text() -> String:
		return "偏移：指定距离 -> 选择对象 -> 点取偏移侧（可连续偏移）"

	func start(_args: Dictionary) -> void:
		_begin("偏移")
		_state = S_DIST
		_pending.clear()
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_DIST:
				return "OFFSET 指定偏移距离:"
			S_SIDE:
				return "OFFSET 选择要偏移的对象:"
			S_MORE:
				return "OFFSET 点取要偏移的那一侧（回车结束）:"
		return ""

	func on_text(s: String) -> bool:
		if _state == S_DIST:
			var v := s.strip_edges().to_float()
			if v > Tol.MIN_LEN:
				_dist = v
				_state = S_SIDE
				ctx.set_status("偏移距离 %.1f。%s" % [_dist, prompt()])
			return false
		return false

	func on_point(p: Vector2) -> bool:
		if _state == S_DIST:
			# 也可用两点指定距离
			if _pending.is_empty():
				_pending.append(p)
				ctx.set_status("OFFSET 指定第二点以确定距离:")
				return false
			_dist = _pending[0].distance_to(p)
			_pending.clear()
			if _dist > Tol.MIN_LEN:
				_state = S_SIDE
				ctx.set_status("偏移距离 %.1f。%s" % [_dist, prompt()])
			return false
		if _state == S_SIDE:
			var e := _pick(p)
			if e == null:
				ctx.set_status("未选中对象，请重新点取")
				return false
			_src = e
			_state = S_MORE
			ctx.set_status(prompt())
			return false
		# 点取偏移侧：由点在原曲线哪一侧决定偏移符号
		if _src == null:
			return false
		var signed := _signed_distance(_src, p)
		if absf(signed) <= Tol.MIN_LEN:
			return false
		var made := CurveOps.offset_entity(_src, signed)
		if made.is_empty():
			ctx.set_status("该对象无法偏移 %.1f（可能半径被吃穿）" % _dist)
			return false
		for m in made:
			ctx.doc.add_entity(m)
		ctx.set_status("已偏移 %d 个对象。%s" % [made.size(), prompt()])
		ctx.request_redraw()
		return false

	## 判断点位于曲线的哪一侧，返回带符号的偏移距离。
	## 正值 = 行进方向左侧，与 CurveOps 的约定一致。
	func _signed_distance(e: CadEntity, p: Vector2) -> float:
		var curves := CurveOps.decompose_all(e)
		var best_d := INF
		var best_sign := 1.0
		for c in curves:
			var r := c.closest_point(p)
			var d: float = r["dist"]
			if d >= best_d:
				continue
			best_d = d
			var t: float = r["t"]
			var tan := c.tangent_at(t)
			var left := Vector2(-tan.y, tan.x)
			var to_p := p - (r["point"] as Vector2)
			best_sign = 1.0 if to_p.dot(left) >= 0.0 else -1.0
		return _dist * best_sign

	func on_enter() -> bool:
		if _state == S_DIST or _state == S_SIDE:
			_finish()
			return true
		_finish()
		return true

	func cancel() -> void:
		_finish()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state == S_DIST and _pending.size() == 1:
			ci.draw_line(view.to_screen(_pending[0]), view.to_screen(p),
				Color(0.55, 0.85, 1.0, 0.9), 1.0, true)
			ci.draw_string(ThemeDB.fallback_font, view.to_screen(p) + Vector2(16, -16),
				"%.1f" % _pending[0].distance_to(p), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 1.0, 0.7))
		elif _state == S_MORE and _src != null:
			# 预览将要生成的偏移结果
			var signed := _signed_distance(_src, p)
			if absf(signed) <= Tol.MIN_LEN:
				return
			var made := CurveOps.offset_entity(_src, signed)
			for m in made:
				_draw_entity_preview(ci, view, m)

	func _draw_entity_preview(ci: CanvasItem, view: ViewTransform, e: CadEntity) -> void:
		var col := Color(0.55, 0.85, 1.0, 0.75)
		for c in e.get_curves():
			var pts := PackedVector2Array()
			for q in c.tessellate(view.sagitta_for_pixels(0.5)):
				pts.append(view.to_screen(q))
			if pts.size() >= 2:
				ci.draw_polyline(pts, col, 1.0, true)


# ===========================================================================
# 修剪 / 延伸
# ===========================================================================

class TrimBase extends PickBase:
	enum { S_BOUNDARY, S_TARGET }
	var _state := S_BOUNDARY
	var _boundaries: Array[CadEntity] = []

	func _is_extend() -> bool:
		return false

	func prompt() -> String:
		if _state == S_BOUNDARY:
			return "%s 选择剪切边（回车确认，已选 %d 个）:" % [
				"EXTEND" if _is_extend() else "TRIM", _boundaries.size()]
		return "%s 选择要%s的对象（回车结束）:" % [
			"EXTEND" if _is_extend() else "TRIM", "延伸" if _is_extend() else "修剪"]

	func start(_args: Dictionary) -> void:
		_begin("延伸" if _is_extend() else "修剪")
		_state = S_BOUNDARY
		_boundaries.clear()
		ctx.set_status(prompt())

	func on_enter() -> bool:
		if _state == S_BOUNDARY:
			if _boundaries.is_empty():
				ctx.set_status("未选择边界，命令取消")
				_finish()
				return true
			_state = S_TARGET
			ctx.set_status(prompt())
			return false
		_finish()
		return true

	func on_point(p: Vector2) -> bool:
		var e := _pick(p)
		if e == null:
			return false
		if _state == S_BOUNDARY:
			if not _boundaries.has(e):
				_boundaries.append(e)
				ctx.set_status(prompt())
			return false
		# 修剪/延伸目标对象
		if _boundaries.has(e):
			return false
		_do_edit(e, p)
		ctx.request_redraw()
		return false

	## 把边界对象展开为曲线集合
	func _boundary_curves() -> Array[GeoCurve]:
		var out: Array[GeoCurve] = []
		for b in _boundaries:
			for c in CurveOps.decompose_all(b):
				out.append(c)
		return out

	func _do_edit(target: CadEntity, pick_pos: Vector2) -> void:
		if target is EntLine or target is EntArc or target is EntCircle or target is EntPolyline:
			var poly := CurveOps.entity_to_poly(target)
			_edit_poly(target, poly, pick_pos)
		else:
			ctx.set_status("%s 不支持该对象类型" % ("EXTEND" if _is_extend() else "TRIM"))

	func _edit_poly(target: CadEntity, poly: GeoPoly, pick_pos: Vector2) -> void:
		var cr := CurveOps.crossings_sorted(poly, _boundary_curves(), _is_extend())
		cr = _filter_crossings(target, cr)
		if cr.is_empty():
			ctx.set_status("该对象与边界没有交点")
			return
		var total := poly.curve_length()
		var pick_d := CurveOps._dist_along(poly, pick_pos)
		var keep := _compute_keep(total, cr, pick_d)
		if keep.size() != 2:
			ctx.set_status("无法确定修剪范围")
			return
		var res := CurveOps.slice_poly(poly, keep[0], keep[1])
		if res.curve_length() <= Tol.MIN_LEN:
			ctx.doc.mark_modified(target)
			ctx.doc.remove_entity(target)
			ctx.set_status("已删除退化对象")
			return
		var ne := EntPolyline.make_from_geo(res)
		_copy_style(target, ne)
		ctx.doc.mark_modified(target)
		ctx.doc.remove_entity(target)
		ctx.doc.add_entity(ne)

	## 目标对象参与比较时要把自己排除掉（自交会产生伪交点在端点处）
	func _filter_crossings(_target: CadEntity, cr: Array) -> Array:
		return cr

	## 计算要保留的弧长区间，子类分别实现
	func _compute_keep(_total: float, _crossings: Array, _pick_d: float) -> Array:
		return []

	func _copy_style(src: CadEntity, dst: CadEntity) -> void:
		dst.layer = src.layer
		dst.color = src.color
		dst.aci = src.aci
		dst.linetype = src.linetype
		dst.lineweight = src.lineweight
		dst.linetype_scale = src.linetype_scale

	func cancel() -> void:
		_finish()


class Trim extends TrimBase:
	func cmd_name() -> String:
		return "TRIM"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["tr"])

	func help_text() -> String:
		return "修剪：先选剪切边，再点取要剪掉的部分"

	## 修剪：找出包含点取位置的那一段，把它从曲线上移除。
	## 点取位置落在第一段之前/最后一段之后时，剪掉端部到第一个/最后一个交点。
	func _compute_keep(total: float, crossings: Array, pick_d: float) -> Array:
		var ds: Array[float] = []
		for c in crossings:
			ds.append(float(c[0]))
		# 找到点取位置所在的区间 [lo, hi]
		var lo := 0.0
		var hi := total
		for i in range(ds.size()):
			if ds[i] <= pick_d:
				lo = ds[i]
			if ds[i] > pick_d:
				hi = ds[i]
				break
		# 剪掉 [lo, hi]，保留 [0,lo] 与 [hi,total]。
		# 返回 keep 区间为空表示"无法用单段表达"，这里取较长的一段保留。
		if lo <= Tol.MIN_LEN and hi >= total - Tol.MIN_LEN:
			return [0.0, total]
		if lo <= Tol.MIN_LEN:
			return [hi, total]
		if hi >= total - Tol.MIN_LEN:
			return [0.0, lo]
		# 中间被剪断：保留较长的一段（多段结果需多次修剪，与 AutoCAD 行为一致）
		if lo >= total - hi:
			return [0.0, lo]
		return [hi, total]


class Extend extends TrimBase:
	func cmd_name() -> String:
		return "EXTEND"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["ex"])

	func help_text() -> String:
		return "延伸：先选边界，再点取要延伸的一端"

	func _is_extend() -> bool:
		return true

	## 延伸：点取端附近，把曲线延伸到最近的边界交点。
	## 需要把目标曲线本身也延长后求交，故用 extend=true 的交点计算。
	func _compute_keep(total: float, crossings: Array, pick_d: float) -> Array:
		var ds: Array[float] = []
		for c in crossings:
			ds.append(float(c[0]))
		# 点在起点附近 -> 向起点方向延伸；点在终点附近 -> 向终点方向延伸
		var near_start := pick_d < total * 0.5
		if near_start:
			var target := 0.0
			for d in ds:
				if d < target:
					target = d
			if target >= -Tol.MIN_LEN:
				return [0.0, total]
			return [target, total]
		var target_end := total
		for d in ds:
			if d > target_end:
				target_end = d
		if target_end <= total + Tol.MIN_LEN:
			return [0.0, total]
		return [0.0, target_end]


# ===========================================================================
# 打断
# ===========================================================================

class Break extends PickBase:
	enum { S_FIRST, S_SECOND }
	var _state := S_FIRST
	var _target: CadEntity = null
	var _p1 := Vector2.ZERO

	func cmd_name() -> String:
		return "BREAK"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["br"])

	func help_text() -> String:
		return "打断：选择对象 -> 第一打断点 -> 第二打断点（两点相同则只断开不删除）"

	func start(_args: Dictionary) -> void:
		_begin("打断")
		_state = S_FIRST
		ctx.set_status(prompt())

	func prompt() -> String:
		if _target == null:
			return "BREAK 选择对象:"
		if _state == S_FIRST:
			return "BREAK 指定第一个打断点:"
		return "BREAK 指定第二个打断点:"

	func on_point(p: Vector2) -> bool:
		if _target == null:
			var e := _pick(p)
			if e == null:
				ctx.set_status("未选中对象")
				return false
			if not (e is EntLine or e is EntArc or e is EntPolyline or e is EntCircle):
				ctx.set_status("该对象类型不支持打断")
				return false
			_target = e
			_state = S_FIRST
			ctx.set_status(prompt())
			return false
		if _state == S_FIRST:
			_p1 = p
			_state = S_SECOND
			ctx.set_status(prompt())
			return false
		_do_break(_p1, p)
		return true

	func _do_break(a: Vector2, b: Vector2) -> void:
		var poly := CurveOps.entity_to_poly(_target)
		var total := poly.curve_length()
		var d1 := CurveOps._dist_along(poly, a)
		var d2 := CurveOps._dist_along(poly, b)
		if d1 > d2:
			var tmp := d1
			d1 = d2
			d2 = tmp
		d1 = clampf(d1, 0.0, total)
		d2 = clampf(d2, 0.0, total)
		var parts := CurveOps.remove_range_poly(poly, d1, d2)
		ctx.doc.mark_modified(_target)
		ctx.doc.remove_entity(_target)
		for p in parts:
			if p.curve_length() > Tol.MIN_LEN:
				var ne := EntPolyline.make_from_geo(p)
				ne.layer = _target.layer
				ne.aci = _target.aci
				ne.color = _target.color
				ne.linetype = _target.linetype
				ne.lineweight = _target.lineweight
				ctx.doc.add_entity(ne)
		_finish()

	func on_enter() -> bool:
		_finish()
		return true

	func cancel() -> void:
		_finish()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state == S_SECOND:
			ci.draw_line(view.to_screen(_p1), view.to_screen(p), Color(0.55, 0.85, 1.0, 0.9), 1.0, true)


# ===========================================================================
# 圆角 / 倒角
# ===========================================================================

class FilletBase extends PickBase:
	enum { S_PARAM, S_FIRST, S_SECOND }
	var _state := S_PARAM
	var _r1 := 0.0
	var _r2 := 0.0
	var _first: CadEntity = null
	var _first_pick := Vector2.ZERO

	func _p1_name() -> String:
		return "半径"

	func start(_args: Dictionary) -> void:
		_begin("圆角" if _p1_name() == "半径" else "倒角")
		_state = S_PARAM
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_PARAM:
				return "%s 指定%s:" % [cmd_name(), _p1_name()]
			S_FIRST:
				return "%s 选择第一个对象:" % cmd_name()
			S_SECOND:
				return "%s 选择第二个对象:" % cmd_name()
		return ""

	func on_text(s: String) -> bool:
		if _state == S_PARAM:
			var v := s.strip_edges().to_float()
			_apply_params(v)
			_state = S_FIRST
			ctx.set_status(prompt())
			return false
		return false

	func _apply_params(v: float) -> void:
		_r1 = v
		_r2 = v

	func on_point(p: Vector2) -> bool:
		if _state == S_PARAM:
			# 点取两点以确定参数（第一点作原点，距离为参数）
			if _first == null:
				_first = EntPoint.make(p)
				ctx.set_status("%s 指定第二点以确定%s:" % [cmd_name(), _p1_name()])
				return false
			_apply_params(_first.position.distance_to(p))
			_first = null
			_state = S_FIRST
			ctx.set_status(prompt())
			return false
		if _state == S_FIRST:
			var e := _pick(p)
			if e == null or not (e is EntLine):
				ctx.set_status("请选择直线")
				return false
			_first = e
			_first_pick = p
			_state = S_SECOND
			ctx.set_status(prompt())
			return false
		var e2 := _pick(p)
		if e2 == null or not (e2 is EntLine) or e2 == _first:
			ctx.set_status("请选择另一条直线")
			return false
		_do_pair(_first as EntLine, e2 as EntLine, _first_pick, p)
		return true

	func _do_pair(_a: EntLine, _b: EntLine, _pa: Vector2, _pb: Vector2) -> void:
		pass

	func on_enter() -> bool:
		_finish()
		return true

	func cancel() -> void:
		_finish()

	## 用切点把原直线裁短（把靠近角点的那一端移到切点）
	func _shorten_line(e: EntLine, corner: Vector2, cut: Vector2) -> EntLine:
		var da := e.p0.distance_to(corner)
		var db := e.p1.distance_to(corner)
		var ne := EntLine.make(e.p0, e.p1)
		ne.layer = e.layer
		ne.aci = e.aci
		ne.color = e.color
		ne.linetype = e.linetype
		ne.lineweight = e.lineweight
		if da <= db:
			ne.p0 = cut
		else:
			ne.p1 = cut
		return ne

	func _replace(old: CadEntity, fresh: CadEntity) -> void:
		ctx.doc.mark_modified(old)
		ctx.doc.remove_entity(old)
		ctx.doc.add_entity(fresh)


class Fillet extends FilletBase:
	func cmd_name() -> String:
		return "FILLET"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["f"])

	func help_text() -> String:
		return "圆角：输入半径 -> 依次点取两条直线（保留点取侧）"

	func _do_pair(a: EntLine, b: EntLine, pa: Vector2, pb: Vector2) -> void:
		if _r1 <= Tol.MIN_LEN:
			# 半径为 0：直接把两条线延伸到交点（AutoCAD 行为）
			_join_at_corner(a, b)
			_finish()
			return
		var res := CurveOps.fillet_segs(
			GeoSeg.make(a.p0, a.p1), GeoSeg.make(b.p0, b.p1), _r1, pa, pb)
		if not res.get("ok", false):
			ctx.set_status("两条直线平行或共线，无法倒圆角")
			_finish()
			return
		var corner: Vector2 = res["corner"]
		var arc: GeoArc = res["arc"]
		_replace(a, _shorten_line(a, corner, res["tangent_a"]))
		_replace(b, _shorten_line(b, corner, res["tangent_b"]))
		var e := EntArc.make(arc.center, arc.radius, arc.start_angle, arc.end_angle)
		e.layer = a.layer
		e.aci = a.aci
		e.color = a.color
		e.linetype = a.linetype
		e.lineweight = a.lineweight
		ctx.doc.add_entity(e)
		_finish()

	## 半径为 0 时把两条线延伸到交点
	func _join_at_corner(a: EntLine, b: EntLine) -> void:
		var hit = CurveOps.line_line(a.p0, a.p1 - a.p0, b.p0, b.p1 - b.p0)
		if hit == null:
			return
		var corner: Vector2 = hit
		_replace(a, _shorten_line(a, corner, corner))
		_replace(b, _shorten_line(b, corner, corner))
		_finish()


class Chamfer extends FilletBase:
	func cmd_name() -> String:
		return "CHAMFER"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["cha"])

	func help_text() -> String:
		return "倒角：输入两个距离（依次输入 d1 d2，或只输一个则等距） -> 点取两条直线"

	func _p1_name() -> String:
		return "第一个倒角距离"

	func _apply_params(v: float) -> void:
		if _r1 <= Tol.MIN_LEN:
			_r1 = v
			_r2 = v
		else:
			_r2 = v

	func _do_pair(a: EntLine, b: EntLine, pa: Vector2, pb: Vector2) -> void:
		if _r1 <= Tol.MIN_LEN:
			ctx.set_status("倒角距离不能为 0")
			_finish()
			return
		var res := CurveOps.chamfer_segs(
			GeoSeg.make(a.p0, a.p1), GeoSeg.make(b.p0, b.p1), _r1, _r2, pa, pb)
		if not res.get("ok", false):
			ctx.set_status("两条直线平行或共线，无法倒角")
			_finish()
			return
		var corner: Vector2 = res["corner"]
		_replace(a, _shorten_line(a, corner, res["cut_a"]))
		_replace(b, _shorten_line(b, corner, res["cut_b"]))
		var e := EntLine.make(res["cut_a"], res["cut_b"])
		e.layer = a.layer
		e.aci = a.aci
		e.color = a.color
		e.linetype = a.linetype
		e.lineweight = a.lineweight
		ctx.doc.add_entity(e)
		_finish()


# ===========================================================================
# 分解 / 合并
# ===========================================================================

class Explode extends PickBase:
	func cmd_name() -> String:
		return "EXPLODE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["x"])

	func help_text() -> String:
		return "分解：点取对象，把多段线/样条/块打散为基本图元"

	func start(_args: Dictionary) -> void:
		_begin("分解")
		ctx.set_status(prompt())

	func prompt() -> String:
		return "EXPLODE 选择要分解的对象:"

	func on_point(p: Vector2) -> bool:
		var e := _pick(p)
		if e == null:
			return false
		var parts := e.explode()
		if parts.is_empty():
			ctx.set_status("该对象无法分解")
			return false
		ctx.doc.mark_modified(e)
		ctx.doc.remove_entity(e)
		for part in parts:
			ctx.doc.add_entity(part)
		ctx.set_status("已分解为 %d 个对象" % parts.size())
		ctx.request_redraw()
		return false

	func on_enter() -> bool:
		_finish()
		return true

	func cancel() -> void:
		_finish()


class Join extends PickBase:
	var _list: Array[CadEntity] = []

	func cmd_name() -> String:
		return "JOIN"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["j"])

	func help_text() -> String:
		return "合并：依次点取首尾相接的对象，回车完成合并"

	func start(_args: Dictionary) -> void:
		_begin("合并")
		_list.clear()
		ctx.set_status(prompt())

	func prompt() -> String:
		return "JOIN 选择要合并的对象（已选 %d 个，回车完成）:" % _list.size()

	func on_point(p: Vector2) -> bool:
		var e := _pick(p)
		if e == null:
			return false
		if _list.has(e):
			return false
		if not (e is EntLine or e is EntArc or e is EntPolyline):
			ctx.set_status("该对象类型不支持合并")
			return false
		_list.append(e)
		ctx.set_status(prompt())
		return false

	func on_enter() -> bool:
		if _list.size() < 2:
			_finish()
			return true
		# 两两尝试首尾相接，直到不能再合并
		var acc := CurveOps.entity_to_poly(_list[0])
		var remaining := _list.duplicate()
		remaining.remove_at(0)
		var merged := true
		while merged and remaining.size() > 0:
			merged = false
			for i in range(remaining.size()):
				var p2 := CurveOps.entity_to_poly(remaining[i])
				var r := CurveOps.try_join(acc, p2)
				if r != null:
					acc = r
					remaining.remove_at(i)
					merged = true
					break
		var style_src: CadEntity = _list[0]
		for e in _list:
			ctx.doc.mark_modified(e)
			ctx.doc.remove_entity(e)
		var ne := EntPolyline.make_from_geo(acc)
		ne.layer = style_src.layer
		ne.aci = style_src.aci
		ne.color = style_src.color
		ne.linetype = style_src.linetype
		ne.lineweight = style_src.lineweight
		ctx.doc.add_entity(ne)
		ctx.set_status("已合并为 1 条多段线，剩余未合并 %d 个对象" % remaining.size())
		_finish()
		return true

	func cancel() -> void:
		_finish()


# ===========================================================================
# 阵列
# ===========================================================================

class ArrayCmd extends CadCommand:
	enum { S_MODE, S_ROWS, S_COLS, S_ROWGAP, S_COLGAP, S_CENTER, S_COUNT, S_ANGLE }
	var _state := S_MODE
	var _rows := 2
	var _cols := 2
	var _row_gap := 0.0
	var _col_gap := 0.0
	var _center := Vector2.ZERO
	var _count := 6
	var _total_angle := TAU
	var _src: Array[CadEntity] = []
	var _ref_x := 0.0
	var _ref_y := 0.0

	func cmd_name() -> String:
		return "ARRAY"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["ar"])

	func help_text() -> String:
		return "阵列：R 矩形阵列（行数/列数/行距/列距）或 P 环形阵列（中心/数量/填充角度）"

	func is_selecting() -> bool:
		return _state == S_MODE and _src.is_empty() and ctx.selection.size() == 0

	func start(_args: Dictionary) -> void:
		ctx.doc.begin_transaction("阵列")
		_state = S_MODE
		_src = ctx.selection.items.duplicate()
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_MODE:
				return "ARRAY 选择对象后回车，或输入阵列类型 [矩形(R)/环形(P)] <R>:"
			S_ROWS:
				return "ARRAY 输入行数 <2>:"
			S_COLS:
				return "ARRAY 输入列数 <2>:"
			S_ROWGAP:
				return "ARRAY 输入行间距:"
			S_COLGAP:
				return "ARRAY 输入列间距:"
			S_CENTER:
				return "ARRAY 指定阵列中心点:"
			S_COUNT:
				return "ARRAY 输入项目数 <6>:"
			S_ANGLE:
				return "ARRAY 输入填充角度 <360>:"
		return ""

	func on_enter() -> bool:
		if _state == S_MODE:
			if ctx.selection.size() > 0:
				_src = ctx.selection.items.duplicate()
				_state = S_ROWS
				ctx.set_status(prompt())
				return false
			ctx.doc.rollback_transaction()
			ctx.set_status("未选择对象")
			return true
		# 后续步骤直接回车采用默认值
		_advance("")
		return false

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_MODE:
				if t.to_upper().begins_with("P"):
					_state = S_CENTER
					ctx.set_status(prompt())
					return false
				_state = S_ROWS
				ctx.set_status(prompt())
				return false
			_:
				return _advance(t)
		return false

	func _advance(t: String) -> bool:
		match _state:
			S_ROWS:
				_rows = maxi(int(t.to_float()) if t != "" else 2, 1)
				_capture_ref()
				_state = S_COLS
			S_COLS:
				_cols = maxi(int(t.to_float()) if t != "" else 2, 1)
				_capture_ref()
				_state = S_ROWGAP
			S_ROWGAP:
				_row_gap = t.to_float() if t != "" else 0.0
				if _row_gap <= Tol.MIN_LEN and _cols <= 1:
					_build_rect()
					return true
				_state = S_COLGAP
			S_COLGAP:
				_col_gap = t.to_float() if t != "" else 0.0
				_build_rect()
				return true
			S_COUNT:
				_count = maxi(int(t.to_float()) if t != "" else 6, 2)
				_state = S_ANGLE
			S_ANGLE:
				_total_angle = deg_to_rad(t.to_float()) if t != "" else TAU
				_build_polar()
				return true
		ctx.set_status(prompt())
		return false

	func on_point(p: Vector2) -> bool:
		match _state:
			S_MODE:
				if _src.is_empty():
					return false
				_capture_ref()
				_state = S_ROWS
				ctx.set_status(prompt())
				return false
			S_ROWGAP:
				_row_gap = absf(p.y - _ref_y)
				_state = S_COLGAP
				ctx.set_status(prompt())
				return false
			S_COLGAP:
				_col_gap = absf(p.x - _ref_x)
				_build_rect()
				return true
			S_CENTER:
				_center = p
				_state = S_COUNT
				ctx.set_status(prompt())
				return false
			S_ANGLE:
				_build_polar()
				return true
		return false

	## 记录阵列基元包围盒的原点，供点取行列距时换算相对距离
	func _capture_ref() -> void:
		var sel := CadSelection.new()
		sel.add_all(_src)
		var bb := sel.bbox()
		_ref_x = bb.position.x
		_ref_y = bb.position.y

	func _build_rect() -> void:
		var dx := _col_gap
		var dy := _row_gap
		if _cols > 1 and dx <= Tol.MIN_LEN:
			ctx.set_status("列间距必须大于 0")
			ctx.doc.rollback_transaction()
			ctx.set_status("")
			return
		if _rows > 1 and dy <= Tol.MIN_LEN:
			ctx.set_status("行间距必须大于 0")
			ctx.doc.rollback_transaction()
			ctx.set_status("")
			return
		var n := 0
		for r in range(_rows):
			for c in range(_cols):
				if r == 0 and c == 0:
					continue
				var delta := Vector2(float(c) * dx, float(r) * dy)
				for e in _src:
					var clone := e.clone()
					if clone == null:
						continue
					clone.handle = 0
					clone.transform_by(Transform2D(0.0, delta))
					ctx.doc.add_entity(clone)
					n += 1
		ctx.doc.commit_transaction()
		ctx.selection.clear()
		ctx.set_status("矩形阵列完成，新增 %d 个对象" % n)

	func _build_polar() -> void:
		if _count < 2:
			ctx.doc.rollback_transaction()
			ctx.set_status("")
			return
		var step := _total_angle / float(_count)
		var n := 0
		for i in range(1, _count):
			var ang := step * float(i)
			var r := Transform2D(ang, Vector2.ZERO)
			var xf := Transform2D(r.x, r.y, _center - r * _center)
			for e in _src:
				var clone := e.clone()
				if clone == null:
					continue
				clone.handle = 0
				clone.transform_by(xf)
				ctx.doc.add_entity(clone)
				n += 1
		ctx.doc.commit_transaction()
		ctx.selection.clear()
		ctx.set_status("环形阵列完成，新增 %d 个对象" % n)

	func cancel() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")
		ctx.selection.clear()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state == S_CENTER:
			var s := view.to_screen(p)
			ci.draw_arc(s, 6.0, 0.0, TAU, 16, Color(1.0, 0.8, 0.4), 1.0, true)
		elif _state == S_COUNT or _state == S_ANGLE:
			var c := view.to_screen(_center)
			ci.draw_line(c - Vector2(8, 0), c + Vector2(8, 0), Color(1.0, 0.8, 0.4), 1.0, false)
			ci.draw_line(c - Vector2(0, 8), c + Vector2(0, 8), Color(1.0, 0.8, 0.4), 1.0, false)
