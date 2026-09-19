class_name CmdLine
extends CadCommand
## 直线命令。可连续绘制多段（每段是一条独立直线，与 AutoCAD 行为一致）。
##
## 交互：
##   点第一个点 -> 点第二个点（画出一条线）-> 继续点，以上一段终点为起点
##   回车/空格 结束；Esc 取消；输入 U 撤销上一段


var _base: Vector2 = Vector2.ZERO
var _has_base := false
var _segments: Array[EntLine] = []


func cmd_name() -> String:
	return "LINE"


func aliases() -> PackedStringArray:
	return PackedStringArray(["l", "line", "直线"])


func help_text() -> String:
	return "直线：连续点取各段端点，回车结束"


func start(_args: Dictionary) -> void:
	_segments.clear()
	points.clear()
	_has_base = false
	ctx.doc.begin_transaction("画直线")
	ctx.set_status(prompt())


func prompt() -> String:
	if not _has_base:
		return "LINE 指定第一个点:"
	return "LINE 指定下一点 [放弃(U)]:"


func _make_segment(a: Vector2, b: Vector2) -> EntLine:
	var e := EntLine.make(a, b)
	apply_defaults(e)
	return e


func on_point(p: Vector2) -> bool:
	if not _has_base:
		_base = p
		_has_base = true
		points.append(p)
		ctx.set_status(prompt())
		ctx.request_redraw()
		return false
	var seg := _make_segment(_base, p)
	ctx.doc.add_entity(seg)
	_segments.append(seg)
	_base = p
	points.append(p)
	ctx.set_status(prompt())
	ctx.request_redraw()
	return false


func on_text(s: String) -> bool:
	var t := s.strip_edges().to_upper()
	if t == "U" and not _segments.is_empty():
		# 放弃最后一段：在事务内删除，撤销栈会记录为"未发生"
		var last: EntLine = _segments.pop_back()
		ctx.doc.remove_entity(last)
		_base = last.p0
		if points.size() > 0:
			points.remove_at(points.size() - 1)
		ctx.set_status(prompt())
		ctx.request_redraw()
		return false
	var r := parse_point(s, _base)
	if r.get("ok", false):
		return on_point(r["point"])
	return false


func on_enter() -> bool:
	# 少于一条线段则整个命令作废；否则提交事务
	if _segments.is_empty():
		ctx.doc.rollback_transaction()
	else:
		ctx.doc.commit_transaction()
	ctx.set_status("")
	return true


func cancel() -> void:
	# 已经画出的线段保留（AutoCAD 的 Esc 行为），只结束命令
	if _segments.is_empty():
		ctx.doc.rollback_transaction()
	else:
		ctx.doc.commit_transaction()
	ctx.set_status("")


func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
	if not _has_base:
		return
	var a := view.to_screen(_base)
	var b := view.to_screen(p)
	ci.draw_line(a, b, Color(0.55, 0.85, 1.0, 0.9), 1.0, true)
	# 长度与角度的实时提示
	var d := _base.distance_to(p)
	var ang := rad_to_deg((p - _base).angle())
	if d > Tol.MIN_LEN:
		var s := "%.1f < %.1f°" % [d, ang]
		var f := ThemeDB.fallback_font
		ci.draw_string(f, b + Vector2(16, -16), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 1.0, 0.7))
