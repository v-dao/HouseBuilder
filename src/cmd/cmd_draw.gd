class_name CmdDraw
extends RefCounted
## 绘制类命令集合。
##
## 用内部类组织而不是一命令一文件：这些命令都以「采集若干点 -> 生成图元」
## 为骨架，放在一起便于对照，也避免二十多个碎文件。


## 绘制命令的公共骨架：事务管理、预览、点/文本分发
class DBase extends CadCommand:
	## 已采集的点
	var pts: PackedVector2Array = PackedVector2Array()

	func _begin(label: String) -> void:
		pts.clear()
		ctx.doc.begin_transaction(label)

	func _commit() -> void:
		ctx.doc.commit_transaction()

	func _rollback() -> void:
		ctx.doc.rollback_transaction()

	## 把图元加入文档（自动套用当前图层/颜色等默认属性）
	func _add(e: CadEntity) -> void:
		apply_defaults(e)
		ctx.doc.add_entity(e)

	func on_mouse_move(p: Vector2) -> void:
		ctx.request_redraw()

	func _preview_line(ci: CanvasItem, view: ViewTransform, a: Vector2, b: Vector2,
			col := Color(0.55, 0.85, 1.0, 0.9)) -> void:
		ci.draw_line(view.to_screen(a), view.to_screen(b), col, 1.0, true)

	## 光标附近的尺寸提示
	func _hint(ci: CanvasItem, view: ViewTransform, p: Vector2, text: String) -> void:
		var s := view.to_screen(p) + Vector2(16, -16)
		ci.draw_string(ThemeDB.fallback_font, s, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color(0.7, 1.0, 0.7))


# ===========================================================================
# 多段线
# ===========================================================================

class Pline extends DBase:
	enum { P_FIRST, P_NEXT }
	var _state := P_FIRST
	var _arc_mode := false
	var _poly: GeoPoly = GeoPoly.new()

	func cmd_name() -> String:
		return "PLINE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["pl"])

	func help_text() -> String:
		return "多段线：A 切圆弧、L 切直线、C 闭合、U 放弃、回车结束"

	func start(_args: Dictionary) -> void:
		_begin("画多段线")
		_state = P_FIRST
		_arc_mode = false
		_poly = GeoPoly.new()
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == P_FIRST:
			return "PLINE 指定起点:"
		return "PLINE 指定下一点 [圆弧(A)/直线(L)/闭合(C)/放弃(U)]:"

	func on_point(p: Vector2) -> bool:
		if _state == P_FIRST:
			_poly.points.append(p)
			_poly.bulges.append(0.0)
			_state = P_NEXT
			ctx.set_status(prompt())
			return false
		_append_point(p)
		return false

	func _append_point(p: Vector2) -> void:
		var n := _poly.points.size()
		var bulge := 0.0
		if _arc_mode and n >= 1:
			# 圆弧模式：弧在前一端点与切向相切。设切向到弦的转角为 φ，
			# 则圆弧圆心角 = 2φ，故 bulge = tan(φ/2)。
			var prev := _poly.points[n - 1]
			var tangent := _incoming_tangent()
			var chord := p - prev
			if chord.length() > Tol.MIN_LEN and tangent != Vector2.ZERO:
				var phi := tangent.angle_to(chord)
				bulge = tan(phi * 0.5)
		if n >= 1:
			_poly.bulges[n - 1] = bulge
		_poly.points.append(p)
		_poly.bulges.append(0.0)
		ctx.request_redraw()

	## 进入当前端点的切向（用于圆弧模式的相切衔接）
	func _incoming_tangent() -> Vector2:
		var n := _poly.points.size()
		if n < 2:
			return Vector2.RIGHT
		var span := _poly.span(n - 2)
		return span.tangent_at(1.0)

	func on_text(s: String) -> bool:
		var t := s.strip_edges().to_upper()
		match t:
			"A":
				_arc_mode = true
				ctx.set_status("PLINE 圆弧模式，指定圆弧终点 [直线(L)]:")
				ctx.request_redraw()
				return false
			"L":
				_arc_mode = false
				ctx.set_status(prompt())
				return false
			"C":
				if _poly.points.size() >= 3:
					_poly.closed = true
					_finish_poly()
					return true
				return false
			"U":
				if _poly.points.size() > 1:
					_poly.points.remove_at(_poly.points.size() - 1)
					_poly.bulges.remove_at(_poly.bulges.size() - 1)
					if _poly.bulges.size() > 0:
						_poly.bulges[_poly.bulges.size() - 1] = 0.0
					ctx.request_redraw()
				return false
		var r := parse_point(s, _poly.points[_poly.points.size() - 1] if _poly.points.size() > 0 else Vector2.ZERO)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	func _finish_poly() -> void:
		if _poly.points.size() >= 2:
			var e := EntPolyline.make_from_geo(_poly)
			_add(e)
		_commit()

	func on_enter() -> bool:
		_finish_poly()
		ctx.set_status("")
		return true

	func cancel() -> void:
		_commit()
		ctx.set_status("")

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _poly.points.is_empty():
			return
		var last := _poly.points[_poly.points.size() - 1]
		_preview_line(ci, view, last, p)
		var d := last.distance_to(p)
		if d > Tol.MIN_LEN:
			_hint(ci, view, p, "%.1f < %.1f°" % [d, rad_to_deg((p - last).angle())])


# ===========================================================================
# 矩形
# ===========================================================================

class Rectang extends DBase:
	var _p0 := Vector2.ZERO
	var _has := false
	var _fillet := 0.0

	func cmd_name() -> String:
		return "RECTANG"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["rec"])

	func help_text() -> String:
		return "矩形：两个对角点；F 指定圆角半径"

	func start(_args: Dictionary) -> void:
		_begin("画矩形")
		_has = false
		ctx.set_status(prompt())

	func prompt() -> String:
		if not _has:
			return "RECTANG 指定第一个角点:"
		return "RECTANG 指定另一个角点:"

	func on_point(p: Vector2) -> bool:
		if not _has:
			_p0 = p
			_has = true
			ctx.set_status(prompt())
			return false
		_add_rect(_p0, p)
		return true

	func _add_rect(a: Vector2, b: Vector2) -> void:
		var x0 := minf(a.x, b.x)
		var y0 := minf(a.y, b.y)
		var w := absf(b.x - a.x)
		var h := absf(b.y - a.y)
		if w <= Tol.MIN_LEN or h <= Tol.MIN_LEN:
			_rollback()
			return
		var poly := _rounded_rect(x0, y0, w, h, _fillet)
		var e := EntPolyline.make_from_geo(poly)
		_add(e)
		_commit()

	## 圆角矩形：四条直边 + 四个 90° 圆弧（bulge = tan(22.5°)）
	func _rounded_rect(x: float, y: float, w: float, h: float, r: float) -> GeoPoly:
		var pts := PackedVector2Array()
		var bls := PackedFloat64Array()
		var rr := clampf(r, 0.0, minf(w, h) * 0.5 - Tol.MIN_LEN)
		if rr <= Tol.MIN_LEN:
			pts = PackedVector2Array([
				Vector2(x, y), Vector2(x + w, y), Vector2(x + w, y + h), Vector2(x, y + h)])
			bls = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
			return GeoPoly.make(pts, bls, true)
		var b := tan(PI / 8.0)
		# 逆时针：左下 -> 右下 -> 右上 -> 左上
		pts.append(Vector2(x + rr, y))
		bls.append(0.0)
		pts.append(Vector2(x + w - rr, y))
		bls.append(b)
		pts.append(Vector2(x + w, y + rr))
		bls.append(0.0)
		pts.append(Vector2(x + w, y + h - rr))
		bls.append(b)
		pts.append(Vector2(x + w - rr, y + h))
		bls.append(0.0)
		pts.append(Vector2(x + rr, y + h))
		bls.append(b)
		pts.append(Vector2(x, y + h - rr))
		bls.append(0.0)
		pts.append(Vector2(x, y + rr))
		bls.append(b)
		return GeoPoly.make(pts, bls, true)

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		if t.to_upper().begins_with("F"):
			var v := t.substr(1).strip_edges().to_float()
			if v > 0.0:
				_fillet = v
				ctx.set_status("已设圆角半径 %.1f" % v)
				return false
		var r := parse_point(s, _p0)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	func on_enter() -> bool:
		_rollback()
		ctx.set_status("")
		return true

	func cancel() -> void:
		if _has:
			_rollback()
		ctx.set_status("")

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if not _has:
			return
		var a := _p0
		var corners := [a, Vector2(p.x, a.y), p, Vector2(a.x, p.y)]
		for i in range(4):
			_preview_line(ci, view, corners[i], corners[(i + 1) % 4])
		_hint(ci, view, p, "%.0f × %.0f" % [absf(p.x - a.x), absf(p.y - a.y)])


# ===========================================================================
# 正多边形
# ===========================================================================

class Polygon extends DBase:
	enum { P_SIDES, P_CENTER, P_MODE, P_RADIUS }
	var _state := P_SIDES
	var _sides := 4
	var _center := Vector2.ZERO
	var _inscribed := true

	func cmd_name() -> String:
		return "POLYGON"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["pol"])

	func help_text() -> String:
		return "正多边形：边数（3~1024）+ 中心 + 内接(I)/外切(C) + 半径"

	func start(_args: Dictionary) -> void:
		_begin("画正多边形")
		_state = P_SIDES
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			P_SIDES:
				return "POLYGON 输入边数 <4>:"
			P_CENTER:
				return "POLYGON 指定正多边形的中心点:"
			P_MODE:
				return "POLYGON 输入选项 [内接于圆(I)/外切于圆(C)] <I>:"
			P_RADIUS:
				return "POLYGON 指定圆的半径:"
		return ""

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			P_SIDES:
				var n := int(t.to_float())
				if n >= 3 and n <= 1024:
					_sides = n
				_state = P_CENTER
				ctx.set_status(prompt())
				return false
			P_MODE:
				if t.to_upper().begins_with("C"):
					_inscribed = false
				elif t.to_upper().begins_with("I"):
					_inscribed = true
				_state = P_RADIUS
				ctx.set_status(prompt())
				return false
			P_RADIUS:
				var r := t.to_float()
				if r > Tol.MIN_LEN:
					_build(r)
				return true
		return false

	func on_point(p: Vector2) -> bool:
		match _state:
			P_SIDES:
				# 直接点取：用默认边数，该点作为中心
				_center = p
				_state = P_MODE
				ctx.set_status(prompt())
				return false
			P_CENTER:
				_center = p
				_state = P_MODE
				ctx.set_status(prompt())
				return false
			P_MODE:
				# 以该点相对中心的方位决定半径（默认内接）
				_build(_center.distance_to(p))
				return true
			P_RADIUS:
				_build(_center.distance_to(p))
				return true
		return false

	## 生成正多边形。
	## 内接于圆：顶点落在半径上，边长 = 2R·sin(π/n)
	## 外切于圆：边与半径相切，顶点半径 = R / cos(π/n)
	func _build(r: float) -> void:
		var rr := r
		if not _inscribed and _sides > 0:
			rr = r / cos(PI / float(_sides))
		if rr <= Tol.MIN_LEN:
			_rollback()
			return
		var pts := PackedVector2Array()
		var bls := PackedFloat64Array()
		for i in range(_sides):
			var a := TAU * float(i) / float(_sides) + PI * 0.5
			pts.append(_center + Vector2(cos(a), sin(a)) * rr)
			bls.append(0.0)
		var e := EntPolyline.make(pts, bls, true)
		_add(e)
		_commit()
		ctx.set_status("")

	func on_enter() -> bool:
		match _state:
			P_SIDES:
				_state = P_CENTER
				ctx.set_status(prompt())
				return false
			P_MODE:
				_context_radius()
				return false
			_:
				_rollback()
				ctx.set_status("")
				return true
		return false

	## 进入半径输入阶段
	func _context_radius() -> void:
		_state = P_RADIUS
		ctx.set_status(prompt())

	func cancel() -> void:
		_rollback()
		ctx.set_status("")

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != P_RADIUS and _state != P_MODE:
			return
		var r := _center.distance_to(p)
		if r <= Tol.MIN_LEN:
			return
		var rr := r if _inscribed else r / cos(PI / float(_sides))
		var prev := Vector2.ZERO
		for i in range(_sides + 1):
			var a := TAU * float(i) / float(_sides) + PI * 0.5
			var q := _center + Vector2(cos(a), sin(a)) * rr
			if i > 0:
				_preview_line(ci, view, prev, q)
			prev = q


# ===========================================================================
# 圆
# ===========================================================================

class CircleCmd extends DBase:
	enum { P_CENTER, P_RADIUS, P_3P1, P_3P2, P_3P3 }
	var _state := P_CENTER
	var _center := Vector2.ZERO
	var _p1 := Vector2.ZERO
	var _p2 := Vector2.ZERO

	func cmd_name() -> String:
		return "CIRCLE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["c"])

	func help_text() -> String:
		return "圆：圆心 + 半径；输入 3P 切换到三点画圆"

	func start(_args: Dictionary) -> void:
		_begin("画圆")
		_state = P_CENTER
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			P_CENTER:
				return "CIRCLE 指定圆心 [三点(3P)]:"
			P_RADIUS:
				return "CIRCLE 指定半径:"
			P_3P1:
				return "CIRCLE 指定圆上第一点:"
			P_3P2:
				return "CIRCLE 指定圆上第二点:"
			P_3P3:
				return "CIRCLE 指定圆上第三点:"
		return ""

	func on_text(s: String) -> bool:
		var t := s.strip_edges().to_upper()
		if _state == P_CENTER and t == "3P":
			_state = P_3P1
			ctx.set_status(prompt())
			return false
		if _state == P_RADIUS:
			var r := t.to_float()
			if r > Tol.MIN_LEN:
				_build(_center, r)
			return true
		var r := parse_point(s, _center)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	func on_point(p: Vector2) -> bool:
		match _state:
			P_CENTER:
				_center = p
				_state = P_RADIUS
				ctx.set_status(prompt())
				return false
			P_RADIUS:
				var r := _center.distance_to(p)
				if r > Tol.MIN_LEN:
					_build(_center, r)
				return true
			P_3P1:
				_p1 = p
				_state = P_3P2
				ctx.set_status(prompt())
				return false
			P_3P2:
				_p2 = p
				_state = P_3P3
				ctx.set_status(prompt())
				return false
			P_3P3:
				# _circumcenter 可能返回 null，故此处不能用 := 推断类型
				var c = _circumcenter(_p1, _p2, p)
				if c == null:
					ctx.set_status("三点共线，无法确定圆")
					return true
				_build(c, (c as Vector2).distance_to(_p1))
				return true
		return false

	func _build(c: Vector2, r: float) -> void:
		var e := EntCircle.make(c, r)
		_add(e)
		_commit()
		ctx.set_status("")

	## 三点定圆（外接圆圆心）
	func _circumcenter(a: Vector2, b: Vector2, c: Vector2) -> Variant:
		var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
		if absf(d) <= 1.0e-9:
			return null
		var a2 := a.length_squared()
		var b2 := b.length_squared()
		var c2 := c.length_squared()
		return Vector2(
			(a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
			(a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)

	func on_enter() -> bool:
		_rollback()
		ctx.set_status("")
		return true

	func cancel() -> void:
		_rollback()
		ctx.set_status("")

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		match _state:
			P_RADIUS:
				var r := _center.distance_to(p)
				_preview_circle(ci, view, _center, r)
				_hint(ci, view, p, "R=%.1f" % r)
			P_3P3:
				var c = _circumcenter(_p1, _p2, p)
				if c != null:
					_preview_circle(ci, view, c, (c as Vector2).distance_to(_p1))

	func _preview_circle(ci: CanvasItem, view: ViewTransform, c: Vector2, r: float) -> void:
		if r <= Tol.MIN_LEN:
			return
		var pts := PackedVector2Array()
		for i in range(65):
			var a := TAU * float(i) / 64.0
			pts.append(view.to_screen(c + Vector2(cos(a), sin(a)) * r))
		ci.draw_polyline(pts, Color(0.55, 0.85, 1.0, 0.9), 1.0, true)


# ===========================================================================
# 圆弧（三点）
# ===========================================================================

class ArcCmd extends DBase:
	enum { P_START, P_THROUGH, P_END }
	var _state := P_START
	var _ps := Vector2.ZERO
	var _pt := Vector2.ZERO

	func cmd_name() -> String:
		return "ARC"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["a"])

	func help_text() -> String:
		return "圆弧：起点、圆弧上一点、终点（三点画弧）"

	func start(_args: Dictionary) -> void:
		_begin("画圆弧")
		_state = P_START
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			P_START:
				return "ARC 指定圆弧起点:"
			P_THROUGH:
				return "ARC 指定圆弧上的点:"
			P_END:
				return "ARC 指定圆弧终点:"
		return ""

	func on_point(p: Vector2) -> bool:
		match _state:
			P_START:
				_ps = p
				_state = P_THROUGH
				ctx.set_status(prompt())
				return false
			P_THROUGH:
				_pt = p
				_state = P_END
				ctx.set_status(prompt())
				return false
			P_END:
				_build(_ps, _pt, p)
				return true
		return false

	func _build(a: Vector2, m: Vector2, b: Vector2) -> void:
		var c = _circumcenter(a, m, b)
		if c == null:
			ctx.set_status("三点共线，无法确定圆弧")
			_rollback()
			return
		var center: Vector2 = c
		var r := center.distance_to(a)
		# 由中点判断走向：逆时针时中点在起点到终点的逆时针弧上
		var a0 := (a - center).angle()
		var a1 := (b - center).angle()
		var am := (m - center).angle()
		var arc: EntArc
		if Tol.angle_in_ccw(am, a0, a1):
			arc = EntArc.make(center, r, a0, a1)
		else:
			arc = EntArc.make(center, r, a1, a0)
		_add(arc)
		_commit()
		ctx.set_status("")

	func _circumcenter(a: Vector2, b: Vector2, c: Vector2) -> Variant:
		var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
		if absf(d) <= 1.0e-9:
			return null
		var a2 := a.length_squared()
		var b2 := b.length_squared()
		var c2 := c.length_squared()
		return Vector2(
			(a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
			(a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)

	func on_enter() -> bool:
		_rollback()
		ctx.set_status("")
		return true

	func cancel() -> void:
		_rollback()
		ctx.set_status("")

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state == P_THROUGH:
			_preview_line(ci, view, _ps, p)
		elif _state == P_END:
			var c = _circumcenter(_ps, _pt, p)
			if c != null:
				var center: Vector2 = c
				var r := center.distance_to(_ps)
				var arc := GeoArc.make(center, r, (_ps - center).angle(), (p - center).angle(), true)
				var pts := PackedVector2Array()
				for q in arc.tessellate(r * 0.01):
					pts.append(view.to_screen(q))
				if pts.size() >= 2:
					ci.draw_polyline(pts, Color(0.55, 0.85, 1.0, 0.9), 1.0, true)


# ===========================================================================
# 椭圆
# ===========================================================================

class EllipseCmd extends DBase:
	enum { P_AXIS1, P_AXIS2, P_DIST }
	var _state := P_AXIS1
	var _a1 := Vector2.ZERO
	var _a2 := Vector2.ZERO

	func cmd_name() -> String:
		return "ELLIPSE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["el"])

	func help_text() -> String:
		return "椭圆：长轴两端点 + 短半轴距离"

	func start(_args: Dictionary) -> void:
		_begin("画椭圆")
		_state = P_AXIS1
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			P_AXIS1:
				return "ELLIPSE 指定长轴第一个端点:"
			P_AXIS2:
				return "ELLIPSE 指定长轴另一个端点:"
			P_DIST:
				return "ELLIPSE 指定短半轴长度:"
		return ""

	func on_point(p: Vector2) -> bool:
		match _state:
			P_AXIS1:
				_a1 = p
				_state = P_AXIS2
				ctx.set_status(prompt())
				return false
			P_AXIS2:
				if _a1.distance_to(p) <= Tol.MIN_LEN:
					return false
				_a2 = p
				_state = P_DIST
				ctx.set_status(prompt())
				return false
			P_DIST:
				_build(_a1.distance_to(_a2) * 0.5)
				return true
		return false

	## 用短半轴与长半轴之比，按光标到长轴的距离确定
	func _build(b: float) -> void:
		var center := (_a1 + _a2) * 0.5
		var a := _a1.distance_to(_a2) * 0.5
		if a <= Tol.MIN_LEN or b <= Tol.MIN_LEN:
			_rollback()
			return
		var rot := (_a2 - _a1).angle()
		_add(EntEllipse.make(center, a, minf(b, a), rot))
		_commit()
		ctx.set_status("")

	func on_text(s: String) -> bool:
		if _state == P_DIST:
			var v := s.strip_edges().to_float()
			if v > Tol.MIN_LEN:
				_build(v)
			return true
		return false

	func on_enter() -> bool:
		_rollback()
		ctx.set_status("")
		return true

	func cancel() -> void:
		_rollback()
		ctx.set_status("")

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state == P_AXIS2:
			_preview_line(ci, view, _a1, p)
		elif _state == P_DIST:
			var center := (_a1 + _a2) * 0.5
			var a := _a1.distance_to(_a2) * 0.5
			var rot := (_a2 - _a1).angle()
			var axis := (_a2 - _a1).normalized()
			var nrm := Vector2(-axis.y, axis.x)
			var b := absf((p - center).dot(nrm))
			if b <= Tol.MIN_LEN:
				return
			var el := GeoEllipse.make(center, a, minf(b, a), rot)
			var pts := PackedVector2Array()
			for q in el.tessellate(a * 0.01):
				pts.append(view.to_screen(q))
			if pts.size() >= 2:
				ci.draw_polyline(pts, Color(0.55, 0.85, 1.0, 0.9), 1.0, true)
			_hint(ci, view, p, "短半轴 %.1f" % minf(b, a))


# ===========================================================================
# 样条曲线
# ===========================================================================

class SplineCmd extends DBase:
	func cmd_name() -> String:
		return "SPLINE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["spl"])

	func help_text() -> String:
		return "样条曲线：依次点取型值点，回车结束（曲线严格通过各点）"

	func start(_args: Dictionary) -> void:
		_begin("画样条")
		ctx.set_status(prompt())

	func prompt() -> String:
		if pts.is_empty():
			return "SPLINE 指定第一个点:"
		return "SPLINE 指定下一点（回车结束，已取 %d 点）:" % pts.size()

	func on_point(p: Vector2) -> bool:
		pts.append(p)
		ctx.set_status(prompt())
		ctx.request_redraw()
		return false

	func on_enter() -> bool:
		if pts.size() >= 2:
			_add(EntSpline.make(pts))
		_commit()
		ctx.set_status("")
		return true

	func cancel() -> void:
		_commit()
		ctx.set_status("")

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if pts.size() < 2:
			return
		var tmp := pts.duplicate()
		tmp.append(p)
		var sp := GeoSpline.make(tmp)
		var poly := sp.tessellate(maxf(sp.bbox().size.length() * 1.0e-4, 0.5))
		var scr := PackedVector2Array()
		for q in poly:
			scr.append(view.to_screen(q))
		if scr.size() >= 2:
			ci.draw_polyline(scr, Color(0.55, 0.85, 1.0, 0.9), 1.0, true)


# ===========================================================================
# 点
# ===========================================================================

class PointCmd extends DBase:
	func cmd_name() -> String:
		return "POINT"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["po"])

	func help_text() -> String:
		return "点：点取位置，可连续点取多个"

	func start(_args: Dictionary) -> void:
		_begin("画点")
		ctx.set_status(prompt())

	func prompt() -> String:
		return "POINT 指定点:"

	func on_point(p: Vector2) -> bool:
		_add(EntPoint.make(p))
		ctx.request_redraw()
		return false

	func on_enter() -> bool:
		_commit()
		ctx.set_status("")
		return true

	func cancel() -> void:
		_commit()
		ctx.set_status("")


# ===========================================================================
# 构造线
# ===========================================================================

class XlineCmd extends DBase:
	enum { P_POINT, P_DIR }
	var _state := P_POINT
	var _base := Vector2.ZERO
	var _ray := false

	func cmd_name() -> String:
		return "XLINE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["xl"])

	func help_text() -> String:
		return "构造线：一点 + 方向；R 切换为射线（单向）"

	func start(_args: Dictionary) -> void:
		_begin("画构造线")
		_state = P_POINT
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			P_POINT:
				return "XLINE 指定点 [射线(R)]:"
			P_DIR:
				return "XLINE 指定通过点（确定方向）:"
		return ""

	func on_text(s: String) -> bool:
		if s.strip_edges().to_upper() == "R":
			_ray = not _ray
			ctx.set_status("已切换为%s" % ("射线" if _ray else "构造线"))
			return false
		return false

	func on_point(p: Vector2) -> bool:
		if _state == P_POINT:
			_base = p
			_state = P_DIR
			ctx.set_status(prompt())
			return false
		var d := p - _base
		if d.length() <= Tol.MIN_LEN:
			return false
		_add(EntXline.make(_base, d, _ray))
		_commit()
		ctx.set_status("")
		return true

	func on_enter() -> bool:
		_rollback()
		ctx.set_status("")
		return true

	func cancel() -> void:
		_rollback()
		ctx.set_status("")

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != P_DIR:
			return
		var d := p - _base
		if d.length() <= Tol.MIN_LEN:
			return
		var dir := d.normalized()
		var far := dir * 100000.0
		var a := _base if _ray else _base - far
		_preview_line(ci, view, a, _base + far)
		_hint(ci, view, p, "%.1f°" % rad_to_deg(dir.angle()))
