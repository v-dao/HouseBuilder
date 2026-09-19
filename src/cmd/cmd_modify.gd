class_name CmdModify
extends RefCounted
## 编辑类命令集合：删除、移动、复制、旋转、缩放、镜像、拉伸。
##
## 交互骨架统一为「先选对象 -> 再指定基点/目标点」，
## 因此抽出 SelBase 承载选择阶段的公共逻辑。


## 需要选择集的编辑命令基类
class SelBase extends CadCommand:
	enum { S_SELECT, S_STEP1, S_STEP2, S_STEP3 }
	var _state := S_SELECT
	var _base := Vector2.ZERO

	func _start_sel(label: String) -> void:
		ctx.doc.begin_transaction(label)
		# 已有预选择集时直接进入下一步
		if ctx.selection.size() > 0:
			_state = S_STEP1
		else:
			_state = S_SELECT
		ctx.set_status(prompt())

	func is_selecting() -> bool:
		return _state == S_SELECT

	## 选择阶段的确认：回车进入下一步
	func _confirm_selection() -> bool:
		if ctx.selection.is_empty():
			ctx.set_status("未选择对象，命令取消")
			ctx.doc.rollback_transaction()
			return true
		_state = S_STEP1
		ctx.set_status(prompt())
		ctx.request_redraw()
		return false

	func selected() -> Array[CadEntity]:
		return ctx.selection.items

	## 选择集在模型空间的整体中心，作为基点/镜像轴默认位置参考
	func sel_center() -> Vector2:
		return ctx.selection.center()

	func _finish() -> void:
		ctx.doc.commit_transaction()
		ctx.set_status("")
		ctx.selection.clear()

	func _abort() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")
		ctx.selection.clear()


# ===========================================================================
# 删除
# ===========================================================================

class Erase extends SelBase:
	func cmd_name() -> String:
		return "ERASE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["e"])

	func help_text() -> String:
		return "删除选中的图元"

	func start(_args: Dictionary) -> void:
		_start_sel("删除")

	func prompt() -> String:
		if _state == S_SELECT:
			return "ERASE 选择对象（回车确认，已选 %d 个）:" % ctx.selection.size()
		return ""

	func on_enter() -> bool:
		if _state == S_SELECT:
			if ctx.selection.is_empty():
				ctx.doc.rollback_transaction()
				ctx.set_status("未选择对象")
				return true
			for e in selected():
				ctx.doc.remove_entity(e)
			_finish()
			return true
		return true

	func on_point(_p: Vector2) -> bool:
		# 选择阶段的点击由视口处理
		return false

	func cancel() -> void:
		_abort()


# ===========================================================================
# 移动
# ===========================================================================

class Move extends SelBase:
	func cmd_name() -> String:
		return "MOVE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["m"])

	func help_text() -> String:
		return "移动：基点 + 目标点"

	func start(_args: Dictionary) -> void:
		_start_sel("移动")

	func prompt() -> String:
		match _state:
			S_SELECT:
				return "MOVE 选择对象（回车确认，已选 %d 个）:" % ctx.selection.size()
			S_STEP1:
				return "MOVE 指定基点:"
			S_STEP2:
				return "MOVE 指定第二个点（位移）:"
		return ""

	func on_enter() -> bool:
		if _state == S_SELECT:
			return _confirm_selection()
		_abort()
		return true

	func on_point(p: Vector2) -> bool:
		match _state:
			S_STEP1:
				_base = p
				_state = S_STEP2
				ctx.set_status(prompt())
				return false
			S_STEP2:
				ctx.selection.translate(ctx.doc, p - _base)
				_finish()
				return true
		return false

	func on_text(s: String) -> bool:
		var r := parse_point(s, _base)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_STEP2:
			return
		ci.draw_line(view.to_screen(_base), view.to_screen(p), Color(0.55, 0.85, 1.0, 0.9), 1.0, true)
		var d := p - _base
		ci.draw_string(ThemeDB.fallback_font, view.to_screen(p) + Vector2(16, -16),
			"位移 %.1f, %.1f" % [d.x, d.y], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 1.0, 0.7))


# ===========================================================================
# 复制
# ===========================================================================

class Copy extends SelBase:
	var _count := 0

	func cmd_name() -> String:
		return "COPY"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["co", "cp"])

	func help_text() -> String:
		return "复制：基点 + 目标点，可连续复制多个，回车结束"

	func start(_args: Dictionary) -> void:
		_start_sel("复制")
		_count = 0

	func prompt() -> String:
		match _state:
			S_SELECT:
				return "COPY 选择对象（回车确认，已选 %d 个）:" % ctx.selection.size()
			S_STEP1:
				return "COPY 指定基点:"
			S_STEP2:
				return "COPY 指定第二个点（已复制 %d 个，回车结束）:" % _count
		return ""

	func on_enter() -> bool:
		if _state == S_SELECT:
			return _confirm_selection()
		_finish()
		return true

	func on_point(p: Vector2) -> bool:
		match _state:
			S_STEP1:
				_base = p
				_state = S_STEP2
				ctx.set_status(prompt())
				return false
			S_STEP2:
				var delta := p - _base
				for e in selected():
					var c := e.clone()
					if c == null:
						continue
					c.handle = 0
					c.transform_by(Transform2D(0.0, delta))
					ctx.doc.add_entity(c)
				_count += 1
				ctx.set_status(prompt())
				ctx.request_redraw()
				return false
		return false

	func on_text(s: String) -> bool:
		var r := parse_point(s, _base)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	func cancel() -> void:
		_finish()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_STEP2:
			return
		ci.draw_line(view.to_screen(_base), view.to_screen(p), Color(0.55, 0.85, 1.0, 0.9), 1.0, true)


# ===========================================================================
# 旋转
# ===========================================================================

class Rotate extends SelBase:
	func cmd_name() -> String:
		return "ROTATE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["ro"])

	func help_text() -> String:
		return "旋转：基点 + 角度（可直接输入角度或点取方向）"

	func start(_args: Dictionary) -> void:
		_start_sel("旋转")

	func prompt() -> String:
		match _state:
			S_SELECT:
				return "ROTATE 选择对象（回车确认，已选 %d 个）:" % ctx.selection.size()
			S_STEP1:
				return "ROTATE 指定基点:"
			S_STEP2:
				return "ROTATE 指定旋转角度:"
		return ""

	func on_enter() -> bool:
		if _state == S_SELECT:
			return _confirm_selection()
		_abort()
		return true

	func on_point(p: Vector2) -> bool:
		match _state:
			S_STEP1:
				_base = p
				_state = S_STEP2
				ctx.set_status(prompt())
				return false
			S_STEP2:
				ctx.selection.rotate(ctx.doc, _base, (p - _base).angle())
				_finish()
				return true
		return false

	func on_text(s: String) -> bool:
		if _state != S_STEP2:
			return false
		var v := s.strip_edges()
		if v.is_valid_float():
			ctx.selection.rotate(ctx.doc, _base, deg_to_rad(v.to_float()))
			_finish()
			return true
		var r := parse_point(s, _base)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_STEP2:
			return
		var a := view.to_screen(_base)
		ci.draw_line(a, view.to_screen(p), Color(0.55, 0.85, 1.0, 0.9), 1.0, true)
		ci.draw_string(ThemeDB.fallback_font, view.to_screen(p) + Vector2(16, -16),
			"%.1f°" % rad_to_deg((p - _base).angle()), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 1.0, 0.7))


# ===========================================================================
# 缩放
# ===========================================================================

class Scale extends SelBase:
	func cmd_name() -> String:
		return "SCALE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["sc"])

	func help_text() -> String:
		return "缩放：基点 + 比例（可直接输入比例或点取参考距离）"

	func start(_args: Dictionary) -> void:
		_start_sel("缩放")

	func prompt() -> String:
		match _state:
			S_SELECT:
				return "SCALE 选择对象（回车确认，已选 %d 个）:" % ctx.selection.size()
			S_STEP1:
				return "SCALE 指定基点:"
			S_STEP2:
				return "SCALE 指定比例:"
		return ""

	func on_enter() -> bool:
		if _state == S_SELECT:
			return _confirm_selection()
		_abort()
		return true

	func on_point(p: Vector2) -> bool:
		match _state:
			S_STEP1:
				_base = p
				_state = S_STEP2
				ctx.set_status(prompt())
				return false
			S_STEP2:
				# 以基点到最后一点的距离相对"参照距离 1 个单位"换算比例会失真，
				# 这里改为：比例 = 基点到当前点的距离 / 基点到选择集中心的距离，
				# 即拖动时以选择集中心对齐光标距离。
				var ref := _base.distance_to(sel_center())
				if ref <= Tol.MIN_LEN:
					return false
				_apply(_base.distance_to(p) / ref)
				return true
		return false

	func _apply(f: float) -> void:
		if f <= Tol.MIN_LEN:
			_abort()
			return
		ctx.selection.scale(ctx.doc, _base, f)
		_finish()

	func on_text(s: String) -> bool:
		if _state != S_STEP2:
			return false
		var v := s.strip_edges()
		if v.is_valid_float() and v.to_float() > 0.0:
			_apply(v.to_float())
			return true
		return false

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_STEP2:
			return
		var ref := _base.distance_to(sel_center())
		if ref <= Tol.MIN_LEN:
			return
		ci.draw_line(view.to_screen(_base), view.to_screen(p), Color(0.55, 0.85, 1.0, 0.9), 1.0, true)
		ci.draw_string(ThemeDB.fallback_font, view.to_screen(p) + Vector2(16, -16),
			"比例 %.3f" % (_base.distance_to(p) / ref), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 1.0, 0.7))


# ===========================================================================
# 镜像
# ===========================================================================

class Mirror extends SelBase:
	var _p1 := Vector2.ZERO
	var _axis := Vector2.ZERO

	func cmd_name() -> String:
		return "MIRROR"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["mi"])

	func help_text() -> String:
		return "镜像：两点确定镜像轴，随后选择是否删除原对象（Y/N）"

	func start(_args: Dictionary) -> void:
		_start_sel("镜像")

	func prompt() -> String:
		match _state:
			S_SELECT:
				return "MIRROR 选择对象（回车确认，已选 %d 个）:" % ctx.selection.size()
			S_STEP1:
				return "MIRROR 指定镜像线的第一点:"
			S_STEP2:
				return "MIRROR 指定镜像线的第二点:"
			S_STEP3:
				return "MIRROR 是否删除源对象? [是(Y)/否(N)] <N>:"
		return ""

	func on_enter() -> bool:
		match _state:
			S_SELECT:
				return _confirm_selection()
			S_STEP3:
				_apply(false)
				return true
		_abort()
		return true

	func on_point(p: Vector2) -> bool:
		match _state:
			S_STEP1:
				_p1 = p
				_state = S_STEP2
				ctx.set_status(prompt())
				return false
			S_STEP2:
				if _p1.distance_to(p) <= Tol.MIN_LEN:
					return false
				_axis = p
				_state = S_STEP3
				ctx.set_status(prompt())
				return false
		return false

	func on_text(s: String) -> bool:
		if _state == S_STEP3:
			var t := s.strip_edges().to_upper()
			if t.begins_with("Y"):
				_apply(true)
				return true
			if t.begins_with("N") or t == "":
				_apply(false)
				return true
			return false
		var r := parse_point(s, _p1)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	## 生成镜像副本；del_src 为真时同时删除原对象
	func _apply(del_src: bool) -> void:
		# duplicate() 返回的是无类型数组，循环变量必须显式标注，
		# 否则 e 为 Variant，e.clone() 的类型无法推断。
		var src: Array[CadEntity] = []
		for s in selected():
			src.append(s)
		for e: CadEntity in src:
			var c := e.clone()
			if c == null:
				continue
			c.handle = 0
			_mirror_entity(c, _p1, _axis)
			ctx.doc.add_entity(c)
		if del_src:
			for e: CadEntity in src:
				ctx.doc.remove_entity(e)
		_finish()

	func _mirror_entity(e: CadEntity, a: Vector2, b: Vector2) -> void:
		var d := b - a
		if d.length() <= Tol.MIN_LEN:
			return
		var fwd := Transform2D(d.angle(), a)
		var flip := Transform2D(Vector2(1.0, 0.0), Vector2(0.0, -1.0), Vector2.ZERO)
		e.transform_by(fwd * flip * fwd.affine_inverse())

	func cancel() -> void:
		_abort()

	## 镜像轴用一条超出视口的长线表示，便于判断方向
	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_STEP2:
			return
		var a := view.to_screen(_p1)
		var b := view.to_screen(p)
		if a.distance_to(b) <= 0.5:
			return
		var d := (b - a).normalized()
		ci.draw_line(a - d * 3000.0, a + d * 3000.0, Color(1.0, 0.7, 0.4, 0.85), 1.0, true)


# ===========================================================================
# 拉伸
# ===========================================================================

class Stretch extends CadCommand:
	enum { S_W1, S_W2, S_BASE, S_DEST }
	var _state := S_W1
	var _w1 := Vector2.ZERO
	var _w2 := Vector2.ZERO
	var _base := Vector2.ZERO
	## 需要移动的定义点：{ entity -> { index -> 是否在窗口内 } }
	var _targets: Array = []

	func cmd_name() -> String:
		return "STRETCH"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["s"])

	func help_text() -> String:
		return "拉伸：交叉窗口框选要拉伸的定义点，再指定基点和位移"

	func start(_args: Dictionary) -> void:
		ctx.doc.begin_transaction("拉伸")
		_state = S_W1
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_W1:
				return "STRETCH 以交叉窗口指定第一个角点:"
			S_W2:
				return "STRETCH 指定对角点:"
			S_BASE:
				return "STRETCH 指定基点:"
			S_DEST:
				return "STRETCH 指定第二个点（位移）:"
		return ""

	func on_point(p: Vector2) -> bool:
		match _state:
			S_W1:
				_w1 = p
				_state = S_W2
				ctx.set_status(prompt())
				return false
			S_W2:
				_w2 = p
				_collect()
				if _targets.is_empty():
					ctx.set_status("窗口内没有可拉伸的定义点")
					ctx.doc.rollback_transaction()
					return true
				_state = S_BASE
				ctx.set_status("已选中 %d 个定义点。%s" % [_point_count(), prompt()])
				ctx.request_redraw()
				return false
			S_BASE:
				_base = p
				_state = S_DEST
				ctx.set_status(prompt())
				return false
			S_DEST:
				_apply(p - _base)
				ctx.doc.commit_transaction()
				ctx.set_status("")
				return true
		return false

	## 找出交叉窗口内的全部定义点。
	## 这是 STRETCH 与 MOVE 的本质区别：只移动窗口内的点，
	## 因此一条直线可以只动一端（被拉伸），两端都在窗口内时整条线平移。
	func _collect() -> void:
		_targets.clear()
		var r := Rect2(_w1, Vector2.ZERO).merge(Rect2(_w2, Vector2.ZERO))
		var cands := ctx.doc.entities
		for e in cands:
			if not e.visible:
				continue
			var l := ctx.doc.get_layer(e.layer)
			if l != null and not l.is_selectable():
				continue
			if not e.get_bbox().intersects(r):
				continue
			var pts := e.get_stretch_points()
			var idx: Array[int] = []
			for i in range(pts.size()):
				if r.has_point(pts[i]):
					idx.append(i)
			if not idx.is_empty():
				_targets.append({"e": e, "idx": idx})

	func _point_count() -> int:
		var n := 0
		for t in _targets:
			n += (t["idx"] as Array).size()
		return n

	func _apply(delta: Vector2) -> void:
		for t in _targets:
			var e: CadEntity = t["e"]
			ctx.doc.mark_modified(e)
			# 索引从大到小移动，避免索引在移动过程中失效
			var idx: Array = (t["idx"] as Array).duplicate()
			idx.sort()
			idx.reverse()
			for i in idx:
				var pts := e.get_stretch_points()
				e.move_stretch_point(int(i), pts[int(i)] + delta)
			ctx.doc.touch(e)

	func on_text(s: String) -> bool:
		var r := parse_point(s, _base)
		if r.get("ok", false):
			return on_point(r["point"])
		return false

	func on_enter() -> bool:
		ctx.doc.rollback_transaction()
		ctx.set_status("")
		return true

	func cancel() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		match _state:
			S_W2:
				var a := view.to_screen(_w1)
				var b := view.to_screen(p)
				# 交叉窗口用虚线框表示（与窗选的实线框区分）
				_dash_rect(ci, a, b)
			S_DEST:
				ci.draw_line(view.to_screen(_base), view.to_screen(p), Color(0.55, 0.85, 1.0, 0.9), 1.0, true)

	## 交叉窗口用虚线矩形，符合 CAD 的视觉约定
	func _dash_rect(ci: CanvasItem, a: Vector2, b: Vector2) -> void:
		var r := Rect2(a, Vector2.ZERO).merge(Rect2(b, Vector2.ZERO))
		var col := Color(0.6, 0.9, 1.0, 0.8)
		var corners := [
			r.position,
			r.position + Vector2(r.size.x, 0),
			r.position + r.size,
			r.position + Vector2(0, r.size.y),
		]
		for i in range(4):
			_dash_line(ci, corners[i], corners[(i + 1) % 4], col)

	func _dash_line(ci: CanvasItem, a: Vector2, b: Vector2, col: Color) -> void:
		var total := a.distance_to(b)
		if total <= 0.1:
			return
		var dir := (b - a) / total
		var pos := 0.0
		var on := true
		while pos < total:
			var step := minf(8.0, total - pos)
			if on:
				ci.draw_line(a + dir * pos, a + dir * (pos + step), col, 1.0, false)
			pos += step
			on = not on
