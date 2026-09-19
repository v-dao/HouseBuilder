class_name CmdSymbol
extends RefCounted
## 国标符号命令。
##
## 符号的几何全由 EntSymbols 依"位置 + 参数 + 出图比例"推导，
## 命令只负责采集位置与少量参数。


class SymBase extends CadCommand:
	func _begin(label: String) -> void:
		ctx.doc.begin_transaction(label)

	func _finish() -> void:
		ctx.doc.commit_transaction()
		ctx.set_status("")

	func _abort() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	func _add(e: CadEntity) -> void:
		e.layer = ctx.doc.current_layer
		e.aci = ctx.doc.current_aci
		ctx.doc.add_entity(e)

	func on_mouse_move(_p: Vector2) -> void:
		ctx.request_redraw()

	func _preview(ci: CanvasItem, view: ViewTransform, e: CadEntity) -> void:
		var col := Color(0.6, 0.9, 1.0, 0.85)
		for c in e.get_curves():
			var pts := PackedVector2Array()
			for q in c.tessellate(view.sagitta_for_pixels(0.5)):
				pts.append(view.to_screen(q))
			if pts.size() >= 2:
				ci.draw_polyline(pts, col, 1.0, true)


# ===========================================================================
# 标高
# ===========================================================================

class Elevation extends SymBase:
	enum { S_POS, S_VALUE }
	var _state := S_POS
	var _pos := Vector2.ZERO

	func cmd_name() -> String:
		return "ELEVATION"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["elev", "bg", "标高"])

	func help_text() -> String:
		return "标高符号：点取位置 -> 输入标高值（单位 mm，可直接回车取 0）"

	func start(_args: Dictionary) -> void:
		_begin("标高符号")
		_state = S_POS
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == S_POS:
			return "ELEVATION 指定标高点:"
		return "ELEVATION 输入标高值 (mm) <0>:"

	func on_point(p: Vector2) -> bool:
		if _state == S_POS:
			_pos = p
			_state = S_VALUE
			ctx.set_status(prompt())
			return false
		return false

	func on_text(s: String) -> bool:
		if _state != S_VALUE:
			return false
		var v := s.strip_edges()
		var val := 0.0
		if v != "":
			# 允许用米为单位输入（含小数点时按米解释），也允许直接给毫米
			if v.contains("."):
				val = v.to_float() * 1000.0
			else:
				val = v.to_float()
		_add(EntSymbols.Elevation.make(_pos, val))
		_finish()
		return true

	func on_enter() -> bool:
		if _state == S_VALUE:
			_add(EntSymbols.Elevation.make(_pos, 0.0))
			_finish()
			return true
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state == S_POS:
			_preview(ci, view, EntSymbols.Elevation.make(p, 0.0))


# ===========================================================================
# 索引符号 / 详图符号
# ===========================================================================

class IndexMark extends SymBase:
	enum { S_POS, S_DETAIL_NO, S_SHEET_NO }
	var _state := S_POS
	var _pos := Vector2.ZERO
	var _detail_no := "1"
	var _is_detail := false

	func _init(is_detail := false) -> void:
		_is_detail = is_detail

	func cmd_name() -> String:
		return "DETAILMARK" if _is_detail else "INDEXMARK"

	func aliases() -> PackedStringArray:
		if _is_detail:
			return PackedStringArray(["dtm", "详图符号"])
		return PackedStringArray(["idx", "索引符号"])

	func help_text() -> String:
		if _is_detail:
			return "详图符号：点取位置 -> 输入详图编号（直径 14mm 粗圆）"
		return "索引符号：点取位置 -> 详图编号 -> 图纸编号（直径 10mm 细圆）"

	func start(_args: Dictionary) -> void:
		_begin(cmd_name())
		_state = S_POS
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_POS:
				return "%s 指定位置:" % cmd_name()
			S_DETAIL_NO:
				return "%s 输入详图编号 <1>:" % cmd_name()
			S_SHEET_NO:
				return "%s 输入图纸编号（回车跳过）:" % cmd_name()
		return ""

	func on_point(p: Vector2) -> bool:
		if _state != S_POS:
			return false
		_pos = p
		_state = S_DETAIL_NO
		ctx.set_status(prompt())
		return false

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_DETAIL_NO:
				if t != "":
					_detail_no = t
				if _is_detail:
					_add(EntSymbols.IndexMark.make_detail(_pos, _detail_no))
					_finish()
					return true
				_state = S_SHEET_NO
				ctx.set_status(prompt())
				return false
			S_SHEET_NO:
				_add(EntSymbols.IndexMark.make_index(_pos, _detail_no, t))
				_finish()
				return true
		return false

	func on_enter() -> bool:
		match _state:
			S_DETAIL_NO:
				if _is_detail:
					_add(EntSymbols.IndexMark.make_detail(_pos, _detail_no))
					_finish()
					return true
				_state = S_SHEET_NO
				ctx.set_status(prompt())
				return false
			S_SHEET_NO:
				_add(EntSymbols.IndexMark.make_index(_pos, _detail_no, ""))
				_finish()
				return true
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_POS:
			return
		if _is_detail:
			_preview(ci, view, EntSymbols.IndexMark.make_detail(p, _detail_no))
		else:
			_preview(ci, view, EntSymbols.IndexMark.make_index(p, _detail_no, ""))


# ===========================================================================
# 剖切符号
# ===========================================================================

class SectionMark extends SymBase:
	enum { S_P1, S_P2, S_SIDE, S_NO }
	var _state := S_P1
	var _p1 := Vector2.ZERO
	var _p2 := Vector2.ZERO
	var _side := 1
	var _no := "1"

	func cmd_name() -> String:
		return "SECTIONMARK"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["sec", "剖切符号"])

	func help_text() -> String:
		return "剖切符号：剖切位置线两端 -> 点取投射方向 -> 输入编号"

	func start(_args: Dictionary) -> void:
		_begin("剖切符号")
		_state = S_P1
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_P1:
				return "SECTIONMARK 指定剖切位置线起点:"
			S_P2:
				return "SECTIONMARK 指定剖切位置线终点:"
			S_SIDE:
				return "SECTIONMARK 点取投射方向侧:"
			S_NO:
				return "SECTIONMARK 输入编号 <1>:"
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
				_state = S_SIDE
			S_SIDE:
				# 由点取位置在剖切线的哪一侧决定投射方向
				var d := _p2 - _p1
				var n := Vector2(-d.y, d.x)
				_side = 1 if (p - _p1).dot(n) >= 0.0 else -1
				_state = S_NO
			S_NO:
				return false
		ctx.set_status(prompt())
		return false

	func on_text(s: String) -> bool:
		if _state != S_NO:
			return false
		var t := s.strip_edges()
		if t != "":
			_no = t
		_add(EntSymbols.SectionMark.make(_p1, _p2, _side, _no))
		_finish()
		return true

	func on_enter() -> bool:
		if _state == S_NO:
			_add(EntSymbols.SectionMark.make(_p1, _p2, _side, _no))
			_finish()
			return true
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		match _state:
			S_P2:
				ci.draw_line(view.to_screen(_p1), view.to_screen(p), Color(0.6, 0.9, 1.0, 0.9), 1.0, true)
			S_SIDE:
				_preview(ci, view, EntSymbols.SectionMark.make(_p1, _p2, _side, _no))


# ===========================================================================
# 引出线
# ===========================================================================

class Leader extends SymBase:
	enum { S_FIRST, S_NEXT, S_TEXT }
	var _state := S_FIRST
	var _pts := PackedVector2Array()

	func cmd_name() -> String:
		return "LEADER"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["le", "引出线"])

	func help_text() -> String:
		return "引出线：点取被标注位置 -> 依次点取折点 -> 回车后输入文字"

	func start(_args: Dictionary) -> void:
		_begin("引出线")
		_state = S_FIRST
		_pts = PackedVector2Array()
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == S_FIRST or _pts.is_empty():
			return "LEADER 指定起点（被标注位置）:"
		if _state == S_NEXT:
			return "LEADER 指定下一点（回车结束折线）:"
		return "LEADER 输入文字内容:"

	func on_point(p: Vector2) -> bool:
		if _state == S_FIRST:
			_pts.append(p)
			_state = S_NEXT
			ctx.set_status(prompt())
			return false
		if _state == S_NEXT:
			_pts.append(p)
			ctx.request_redraw()
			return false
		return false

	func on_text(s: String) -> bool:
		if _state == S_TEXT:
			_add(EntSymbols.Leader.make(_pts, s.strip_edges()))
			_finish()
			return true
		return false

	func on_enter() -> bool:
		if _state == S_NEXT and _pts.size() >= 2:
			_state = S_TEXT
			ctx.set_status(prompt())
			return false
		if _state == S_TEXT:
			_add(EntSymbols.Leader.make(_pts, ""))
			_finish()
			return true
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _pts.is_empty() or _state != S_NEXT:
			return
		var scr := PackedVector2Array()
		for q in _pts:
			scr.append(view.to_screen(q))
		scr.append(view.to_screen(p))
		if scr.size() >= 2:
			ci.draw_polyline(scr, Color(0.6, 0.9, 1.0, 0.9), 1.0, true)


# ===========================================================================
# 折断线 / 波浪线
# ===========================================================================

class BreakLine extends SymBase:
	enum { S_P1, S_P2 }
	var _state := S_P1
	var _p1 := Vector2.ZERO
	var _wavy := false

	func _init(wavy := false) -> void:
		_wavy = wavy

	func cmd_name() -> String:
		return "WAVYLINE" if _wavy else "BREAKLINE"

	func aliases() -> PackedStringArray:
		if _wavy:
			return PackedStringArray(["wavy", "波浪线"])
		return PackedStringArray(["bkl", "折断线"])

	func help_text() -> String:
		if _wavy:
			return "波浪线：两点确定走向（曲线折断用）"
		return "折断线：两点确定走向（直线折断画成 Z 字形）"

	func start(_args: Dictionary) -> void:
		_begin(cmd_name())
		_state = S_P1
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == S_P1:
			return "%s 指定起点:" % cmd_name()
		return "%s 指定终点:" % cmd_name()

	func on_point(p: Vector2) -> bool:
		if _state == S_P1:
			_p1 = p
			_state = S_P2
			ctx.set_status(prompt())
			return false
		if _p1.distance_to(p) <= Tol.MIN_LEN:
			return false
		_add(EntSymbols.BreakLine.make(_p1, p, _wavy))
		_finish()
		return true

	func on_enter() -> bool:
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_P2:
			return
		_preview(ci, view, EntSymbols.BreakLine.make(_p1, p, _wavy))


# ===========================================================================
# 轴线号
# ===========================================================================

class AxisBubble extends SymBase:
	enum { S_POS, S_LABEL }
	var _state := S_POS
	var _pos := Vector2.ZERO

	func cmd_name() -> String:
		return "AXISBUBBLE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["axb", "轴线号"])

	func help_text() -> String:
		return "轴线号：点取位置 -> 输入编号（横向用数字、纵向用字母，不采用 I O Z）"

	func start(_args: Dictionary) -> void:
		_begin("轴线号")
		_state = S_POS
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == S_POS:
			return "AXISBUBBLE 指定轴线号位置:"
		return "AXISBUBBLE 输入轴线编号:"

	func on_point(p: Vector2) -> bool:
		if _state == S_POS:
			_pos = p
			_state = S_LABEL
			ctx.set_status(prompt())
		return false

	func on_text(s: String) -> bool:
		if _state != S_LABEL:
			return false
		var t := s.strip_edges().to_upper()
		if t == "":
			return false
		_add(EntSymbols.AxisBubble.make(_pos, t))
		_finish()
		return true

	func on_enter() -> bool:
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state == S_POS:
			_preview(ci, view, EntSymbols.AxisBubble.make(p, "1"))
