class_name CmdText
extends RefCounted
## 文字命令：单行文字、多行文字。


class TextBase extends CadCommand:
	func _begin(label: String) -> void:
		ctx.doc.begin_transaction(label)

	func _finish() -> void:
		ctx.doc.commit_transaction()
		ctx.set_status("")

	func _abort() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	## 取文档当前文字样式的字高作为默认值
	func _default_height() -> float:
		var st := ctx.doc.get_text_style(ctx.doc.current_text_style)
		if st != null and st.height > 0.0:
			return st.height
		return 3.5

	func _add(e: CadEntity) -> void:
		e.layer = ctx.doc.current_layer
		e.aci = ctx.doc.current_aci
		ctx.doc.add_entity(e)

	func on_mouse_move(_p: Vector2) -> void:
		ctx.request_redraw()

	## 预览：把文字以占位框表示，避免每帧排版
	func _preview_box(ci: CanvasItem, view: ViewTransform, pos: Vector2, w_mm: float, h_mm: float) -> void:
		var a := view.to_screen(pos)
		var b := view.to_screen(pos + Vector2(w_mm, -h_mm))
		var r := Rect2(a, Vector2.ZERO).merge(Rect2(b, Vector2.ZERO))
		ci.draw_rect(r, Color(0.6, 0.9, 1.0, 0.5), false, 1.0)


# ===========================================================================
# 单行文字
# ===========================================================================

class TextSingle extends TextBase:
	enum { S_POS, S_HEIGHT, S_CONTENT }
	var _state := S_POS
	var _pos := Vector2.ZERO
	var _height := 0.0

	func cmd_name() -> String:
		return "TEXT"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["dt", "t", "文字"])

	func help_text() -> String:
		return "单行文字：位置 -> 字高（可回车取样式默认值）-> 内容"

	func start(_args: Dictionary) -> void:
		_begin("单行文字")
		_state = S_POS
		_height = _default_height()
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_POS:
				return "TEXT 指定文字起点:"
			S_HEIGHT:
				return "TEXT 指定字高 <%.1f>:" % _height
			S_CONTENT:
				return "TEXT 输入文字内容:"
		return ""

	func on_point(p: Vector2) -> bool:
		if _state == S_POS:
			_pos = p
			_state = S_HEIGHT
			ctx.set_status(prompt())
			return false
		return false

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_HEIGHT:
				# 直接输入内容时按默认字高处理
				if t.is_valid_float() and t.to_float() > 0.0:
					_height = t.to_float()
					_state = S_CONTENT
					ctx.set_status(prompt())
					return false
				_state = S_CONTENT
				return _emit(t)
			S_CONTENT:
				return _emit(s)
		return false

	func _emit(content: String) -> bool:
		if content.strip_edges() != "":
			var e := EntText.make(_pos, content, _height)
			e.text_style = ctx.doc.current_text_style
			_add(e)
		_finish()
		return true

	func on_enter() -> bool:
		match _state:
			S_HEIGHT:
				_state = S_CONTENT
				ctx.set_status(prompt())
				return false
			S_CONTENT:
				_finish()
				return true
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state == S_POS:
			_preview_box(ci, view, p, _height * 4.0, _height)


# ===========================================================================
# 多行文字
# ===========================================================================

class TextMulti extends TextBase:
	enum { S_P1, S_P2, S_HEIGHT, S_CONTENT }
	var _state := S_P1
	var _p1 := Vector2.ZERO
	var _p2 := Vector2.ZERO
	var _height := 0.0

	func cmd_name() -> String:
		return "MTEXT"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["mt", "多行文字"])

	func help_text() -> String:
		return "多行文字：两个对角点定字宽框 -> 字高 -> 内容（内容中可用 \\n 分段）"

	func start(_args: Dictionary) -> void:
		_begin("多行文字")
		_state = S_P1
		_height = _default_height()
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_P1:
				return "MTEXT 指定第一个角点（文字框左上角）:"
			S_P2:
				return "MTEXT 指定对角点（决定字宽，回车表示不自动换行）:"
			S_HEIGHT:
				return "MTEXT 指定字高 <%.1f>:" % _height
			S_CONTENT:
				return "MTEXT 输入文字内容:"
		return ""

	func on_point(p: Vector2) -> bool:
		if _state == S_P1:
			_p1 = p
			_state = S_P2
			ctx.set_status(prompt())
			return false
		if _state == S_P2:
			_p2 = p
			_state = S_HEIGHT
			ctx.set_status(prompt())
			return false
		return false

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_HEIGHT:
				if t.is_valid_float() and t.to_float() > 0.0:
					_height = t.to_float()
					_state = S_CONTENT
					ctx.set_status(prompt())
					return false
				_state = S_CONTENT
				return _emit(t)
			S_CONTENT:
				return _emit(s)
		return false

	func _emit(content: String) -> bool:
		if content.strip_edges() != "":
			var e := EntMText.make(_p1, content.replace("\\n", "\n"), _height)
			e.width = absf(_p2.x - _p1.x) if _state != S_P1 else 0.0
			e.attach = EntMText.Attach.TOP_LEFT
			e.text_style = ctx.doc.current_text_style
			_add(e)
		_finish()
		return true

	func on_enter() -> bool:
		match _state:
			S_P2:
				# 不指定对角点：不自动换行
				_p2 = _p1
				_state = S_HEIGHT
				ctx.set_status(prompt())
				return false
			S_HEIGHT:
				_state = S_CONTENT
				ctx.set_status(prompt())
				return false
			S_CONTENT:
				_finish()
				return true
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		match _state:
			S_P2:
				var a := view.to_screen(_p1)
				var b := view.to_screen(p)
				ci.draw_rect(Rect2(a, Vector2.ZERO).merge(Rect2(b, Vector2.ZERO)),
					Color(0.6, 0.9, 1.0, 0.7), false, 1.0)
			S_HEIGHT, S_CONTENT:
				_preview_box(ci, view, _p1, absf(_p2.x - _p1.x), _height)


# ===========================================================================
# 修改文字内容
# ===========================================================================

class TextChange extends TextBase:
	enum { S_PICK, S_CONTENT }
	var _state := S_PICK
	var _target: CadEntity = null

	func cmd_name() -> String:
		return "TEXTEDIT"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["ddedit", "ed", "改文字"])

	func help_text() -> String:
		return "修改文字：点取文字图元 -> 输入新内容"

	func start(args := {}) -> void:
		_begin("修改文字")
		_state = S_PICK
		# 允许由双击直接传入目标图元
		if args.has("entity"):
			_target = args["entity"]
			_state = S_CONTENT
			ctx.set_status("当前内容：%s\n%s" % [_current_text(), prompt()])
		else:
			ctx.set_status(prompt())

	func _current_text() -> String:
		if _target is EntText:
			return (_target as EntText).text
		if _target is EntMText:
			return (_target as EntMText).text
		return ""

	func prompt() -> String:
		if _state == S_PICK:
			return "TEXTEDIT 选择要修改的文字:"
		return "TEXTEDIT 输入新内容（回车保留原内容）:"

	func on_point(p: Vector2) -> bool:
		if _state != S_PICK:
			return false
		var tol := ctx.view.tolerance_for_pixels(8.0)
		var e := CadSelection.pick(ctx.doc, ctx.index, p, tol)
		if e == null or not (e is EntText or e is EntMText):
			ctx.set_status("请选择文字图元")
			return false
		_target = e
		_state = S_CONTENT
		ctx.set_status("当前内容：%s\n%s" % [_current_text(), prompt()])
		return false

	func on_text(s: String) -> bool:
		if _state != S_CONTENT or _target == null:
			return false
		ctx.doc.mark_modified(_target)
		if _target is EntText:
			(_target as EntText).text = s
			(_target as EntText).measured_valid = false
		elif _target is EntMText:
			(_target as EntMText).text = s.replace("\\n", "\n")
			(_target as EntMText).measured_valid = false
		ctx.doc.touch(_target)
		_finish()
		return true

	func on_enter() -> bool:
		if _state == S_CONTENT:
			_finish()
			return true
		_abort()
		return true

	func cancel() -> void:
		_abort()
