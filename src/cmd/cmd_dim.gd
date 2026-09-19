class_name CmdDim
extends RefCounted
## 尺寸标注命令。
##
## 标注与普通图元最大的不同：它的几何不是用户直接画的，而是由**被标注的点**
## 和**标注样式**推导出来的。因此命令只负责采集定义点，几何全交给 EntDim。


class DimBase extends CadCommand:
	func _begin(label: String) -> void:
		ctx.doc.begin_transaction(label)

	func _finish() -> void:
		ctx.doc.commit_transaction()
		ctx.set_status("")

	func _abort() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	## 新建标注：套用文档当前的标注样式与图层
	func _add_dim(d: EntDim) -> void:
		d.dim_style_name = ctx.doc.current_dim_style
		d.text_style_name = "标注_2.5"
		d.layer = ctx.doc.current_layer
		d.aci = ctx.doc.current_aci
		ctx.doc.add_entity(d)

	func on_mouse_move(_p: Vector2) -> void:
		ctx.request_redraw()

	## 预览：把将要生成的标注以高亮画出来
	func _preview_dim(ci: CanvasItem, view: ViewTransform, d: EntDim) -> void:
		var col := Color(0.6, 0.9, 1.0, 0.85)
		for c in d.get_curves():
			var pts := PackedVector2Array()
			for q in c.tessellate(view.sagitta_for_pixels(0.5)):
				pts.append(view.to_screen(q))
			if pts.size() >= 2:
				ci.draw_polyline(pts, col, 1.0, true)
		# 文字预览
		for a in d.get_annotation_texts():
			var pos := view.to_screen(a["position"])
			ci.draw_string(ThemeDB.fallback_font, pos, String(a["text"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.8, 1.0, 0.8))


# ===========================================================================
# 线性标注
# ===========================================================================

class DimLinear extends DimBase:
	enum { S_P1, S_P2, S_LOC }
	var _state := S_P1
	var _p1 := Vector2.ZERO
	var _p2 := Vector2.ZERO

	func cmd_name() -> String:
		return "DIMLINEAR"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["dli", "dl"])

	func help_text() -> String:
		return "线性标注：两点 + 尺寸线位置（按尺寸线在哪一侧自动判水平/竖直）"

	func start(_args: Dictionary) -> void:
		_begin("线性标注")
		_state = S_P1
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_P1:
				return "DIMLINEAR 指定第一条尺寸界线原点:"
			S_P2:
				return "DIMLINEAR 指定第二条尺寸界线原点:"
			S_LOC:
				return "DIMLINEAR 指定尺寸线位置:"
		return ""

	func on_point(p: Vector2) -> bool:
		match _state:
			S_P1:
				_p1 = p
				_state = S_P2
			S_P2:
				if _p1.distance_to(p) <= Tol.MIN_LEN:
					return false
				_p2 = p
				_state = S_LOC
			S_LOC:
				_add_dim(EntDim.make_linear(_p1, _p2, p))
				_finish()
				return true
		ctx.set_status(prompt())
		return false

	func on_text(s: String) -> bool:
		var r := parse_point(s, _p1 if _state == S_P2 else _p2)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	func on_enter() -> bool:
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		match _state:
			S_P2:
				ci.draw_line(view.to_screen(_p1), view.to_screen(p), Color(0.6, 0.9, 1.0, 0.9), 1.0, true)
			S_LOC:
				_preview_dim(ci, view, EntDim.make_linear(_p1, _p2, p))


# ===========================================================================
# 对齐标注
# ===========================================================================

class DimAligned extends DimBase:
	enum { S_P1, S_P2, S_LOC }
	var _state := S_P1
	var _p1 := Vector2.ZERO
	var _p2 := Vector2.ZERO

	func cmd_name() -> String:
		return "DIMALIGNED"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["dal", "dla"])

	func help_text() -> String:
		return "对齐标注：两点 + 尺寸线位置，尺寸线平行于两点连线"

	func start(_args: Dictionary) -> void:
		_begin("对齐标注")
		_state = S_P1
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_P1:
				return "DIMALIGNED 指定第一条尺寸界线原点:"
			S_P2:
				return "DIMALIGNED 指定第二条尺寸界线原点:"
			S_LOC:
				return "DIMALIGNED 指定尺寸线位置:"
		return ""

	func on_point(p: Vector2) -> bool:
		match _state:
			S_P1:
				_p1 = p
				_state = S_P2
			S_P2:
				if _p1.distance_to(p) <= Tol.MIN_LEN:
					return false
				_p2 = p
				_state = S_LOC
			S_LOC:
				_add_dim(EntDim.make_aligned(_p1, _p2, p))
				_finish()
				return true
		ctx.set_status(prompt())
		return false

	func on_text(s: String) -> bool:
		var r := parse_point(s, _p1 if _state == S_P2 else _p2)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	func on_enter() -> bool:
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		match _state:
			S_P2:
				ci.draw_line(view.to_screen(_p1), view.to_screen(p), Color(0.6, 0.9, 1.0, 0.9), 1.0, true)
			S_LOC:
				_preview_dim(ci, view, EntDim.make_aligned(_p1, _p2, p))


# ===========================================================================
# 半径 / 直径标注
# ===========================================================================

class DimRadial extends DimBase:
	enum { S_OBJ, S_POS }
	var _state := S_OBJ
	var _center := Vector2.ZERO
	var _arc_pt := Vector2.ZERO
	var _diameter := false

	func _init(is_diameter := false) -> void:
		_diameter = is_diameter

	func cmd_name() -> String:
		return "DIMDIAMETER" if _diameter else "DIMRADIUS"

	func aliases() -> PackedStringArray:
		if _diameter:
			return PackedStringArray(["ddi"])
		return PackedStringArray(["dra"])

	func help_text() -> String:
		if _diameter:
			return "直径标注：点取圆或圆弧，再指定文字位置"
		return "半径标注：点取圆或圆弧，再指定文字位置"

	func start(_args: Dictionary) -> void:
		_begin(cmd_name())
		_state = S_OBJ
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == S_OBJ:
			return "%s 选择圆或圆弧:" % cmd_name()
		return "%s 指定尺寸线位置:" % cmd_name()

	func on_point(p: Vector2) -> bool:
		if _state == S_OBJ:
			var tol := ctx.view.tolerance_for_pixels(8.0)
			var e := CadSelection.pick(ctx.doc, ctx.index, p, tol)
			var arc := _as_arc(e)
			if arc == null:
				ctx.set_status("请选择圆或圆弧")
				return false
			_center = (arc as GeoArc).center
			# 用点取位置在圆上的投影作为标注引线的落点
			var r := (arc as GeoArc).radius
			var v := p - _center
			_arc_pt = _center + (v.normalized() if v.length() > Tol.MIN_LEN else Vector2.RIGHT) * r
			_state = S_POS
			ctx.set_status(prompt())
			return false
		if _diameter:
			_add_dim(EntDim.make_diameter(_center, _arc_pt, p))
		else:
			_add_dim(EntDim.make_radius(_center, _arc_pt, p))
		_finish()
		return true

	## 从图元取出圆弧几何（圆、圆弧、含圆弧段的多段线都支持）
	func _as_arc(e: CadEntity) -> GeoArc:
		if e == null:
			return null
		for c in e.get_curves():
			if c.kind() == GeoCurve.Kind.ARC:
				return c as GeoArc
			if c.kind() == GeoCurve.Kind.POLY:
				for sp in (c as GeoPoly).spans():
					if sp.kind() == GeoCurve.Kind.ARC:
						return sp as GeoArc
		return null

	func on_enter() -> bool:
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_POS:
			return
		var d := EntDim.make_diameter(_center, _arc_pt, p) if _diameter \
			else EntDim.make_radius(_center, _arc_pt, p)
		_preview_dim(ci, view, d)


# ===========================================================================
# 角度标注
# ===========================================================================

class DimAngular extends DimBase:
	enum { S_VERTEX, S_RAY1, S_RAY2, S_ARC }
	var _state := S_VERTEX
	var _vertex := Vector2.ZERO
	var _r1 := Vector2.ZERO
	var _r2 := Vector2.ZERO

	func cmd_name() -> String:
		return "DIMANGULAR"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["dan", "da"])

	func help_text() -> String:
		return "角度标注：顶点 + 两条边上的点 + 圆弧位置"

	func start(_args: Dictionary) -> void:
		_begin("角度标注")
		_state = S_VERTEX
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_VERTEX:
				return "DIMANGULAR 指定角的顶点:"
			S_RAY1:
				return "DIMANGULAR 指定第一条边上的点:"
			S_RAY2:
				return "DIMANGULAR 指定第二条边上的点:"
			S_ARC:
				return "DIMANGULAR 指定标注圆弧位置:"
		return ""

	func on_point(p: Vector2) -> bool:
		match _state:
			S_VERTEX:
				_vertex = p
				_state = S_RAY1
			S_RAY1:
				if _vertex.distance_to(p) <= Tol.MIN_LEN:
					return false
				_r1 = p
				_state = S_RAY2
			S_RAY2:
				if _vertex.distance_to(p) <= Tol.MIN_LEN:
					return false
				_r2 = p
				_state = S_ARC
			S_ARC:
				_add_dim(EntDim.make_angular(_vertex, _r1, _r2, p))
				_finish()
				return true
		ctx.set_status(prompt())
		return false

	func on_enter() -> bool:
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		match _state:
			S_RAY1:
				ci.draw_line(view.to_screen(_vertex), view.to_screen(p), Color(0.6, 0.9, 1.0, 0.9), 1.0, true)
			S_RAY2:
				ci.draw_line(view.to_screen(_vertex), view.to_screen(_r1), Color(0.6, 0.9, 1.0, 0.9), 1.0, true)
				ci.draw_line(view.to_screen(_vertex), view.to_screen(p), Color(0.6, 0.9, 1.0, 0.9), 1.0, true)
			S_ARC:
				_preview_dim(ci, view, EntDim.make_angular(_vertex, _r1, _r2, p))


# ===========================================================================
# 连续标注 / 基线标注
# ===========================================================================

class DimChain extends DimBase:
	enum { S_BASE, S_NEXT }
	var _state := S_BASE
	## 链式标注的基准点（连续标注的上一尺寸界线 / 基线标注的公共基准）
	var _anchor := Vector2.ZERO
	var _stack := 0
	var _baseline := false
	## 已生成的标注，用于累计偏移
	var _last_end := Vector2.ZERO

	func _init(is_baseline := false) -> void:
		_baseline = is_baseline

	func cmd_name() -> String:
		return "DIMBASELINE" if _baseline else "DIMCONTINUE"

	func aliases() -> PackedStringArray:
		if _baseline:
			return PackedStringArray(["dimbase", "dba"])
		return PackedStringArray(["dco", "dimcont"])

	func help_text() -> String:
		if _baseline:
			return "基线标注：指定第二条尺寸界线原点，各尺寸共用同一基准并逐层偏移"
		return "连续标注：指定下一条尺寸界线原点，尺寸线首尾相接"

	func start(_args: Dictionary) -> void:
		_begin(cmd_name())
		_state = S_BASE
		_stack = 0
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == S_BASE:
			return "%s 指定第一个尺寸界线原点:" % cmd_name()
		return "%s 指定下一条尺寸界线原点（回车结束）:" % cmd_name()

	func on_point(p: Vector2) -> bool:
		if _state == S_BASE:
			_anchor = p
			_state = S_NEXT
			ctx.set_status(prompt())
			return false
		var a := _anchor
		var b := p
		var st := ctx.doc.get_dim_style(ctx.doc.current_dim_style)
		# GB 规定尺寸线距图样轮廓线不宜小于 10mm，此处取样式里的 origin_offset
		var base_off := st.origin_offset if st != null else 10.0
		var spacing := st.baseline_spacing if st != null else 8.0
		if _baseline:
			# 基线标注：所有尺寸共用同一基准，每层再往外让一个平行尺寸线间距
			_stack += 1
			_add_chain(a, b, base_off + spacing * float(_stack - 1))
			# 基准保持不变
		else:
			# 连续标注：尺寸线首尾相接，基准推进到当前点
			_add_chain(a, b, base_off)
			_anchor = b
		ctx.set_status(prompt())
		ctx.request_redraw()
		return false

	## 生成一条标注。
	## offset_paper 是尺寸线相对被标注线的偏移量，单位是**图纸毫米**
	## （GB 要求尺寸线距轮廓线不小于 10mm），内部按出图比例换算到模型空间。
	## 方向由两点连线的走向决定：横向跨度大就做水平标注、尺寸线在其下方。
	func _add_chain(a: Vector2, b: Vector2, offset_paper: float) -> void:
		var st := ctx.doc.get_dim_style(ctx.doc.current_dim_style)
		var scale := st.overall_scale if st != null else 100.0
		var off := -offset_paper * scale
		var mid := (a + b) * 0.5
		var d := b - a
		var loc: Vector2
		if absf(d.x) >= absf(d.y):
			loc = Vector2(mid.x, mid.y + off)
		else:
			loc = Vector2(mid.x + off, mid.y)
		_add_dim(EntDim.make_linear(a, b, loc))

	func on_enter() -> bool:
		_finish()
		return true

	func cancel() -> void:
		_finish()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_NEXT:
			return
		ci.draw_line(view.to_screen(_anchor), view.to_screen(p), Color(0.6, 0.9, 1.0, 0.9), 1.0, true)
		var mid := (_anchor + p) * 0.5
		var loc := Vector2(mid.x, mid.y - 800.0)
		_preview_dim(ci, view, EntDim.make_linear(_anchor, p, loc))
