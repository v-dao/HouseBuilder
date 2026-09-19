class_name CmdSheet
extends RefCounted
## 插入图框命令。
##
## 图框按 1:1 图纸尺寸生成，而模型空间是真实尺寸（1:1 毫米），
## 因此插入时按文档的出图比例整体放大 —— 这样 1:100 的平面图
## 与 A3 图框在模型空间里尺寸是匹配的，可以直接框住图纸内容。
##
## 标题栏字段按顺序询问，回车即跳过（留空），事后可用改文字命令补填。


class SheetCmd extends CadCommand:
	enum { S_FORMAT, S_ORIENT, S_PROJECT, S_DRAWING, S_NUMBER, S_DONE }
	var _state := S_FORMAT
	var _format := "A3"
	var _portrait := false
	var _fields := {}


	func cmd_name() -> String:
		return "SHEET"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["frame", "图框"])

	func help_text() -> String:
		return "插入图框：幅面（如 A3 / A3X3）-> 横竖式 -> 标题栏各字段（回车跳过）"

	func start(_args: Dictionary) -> void:
		ctx.doc.begin_transaction("插入图框")
		_state = S_FORMAT
		_fields = {}
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_FORMAT:
				return "SHEET 输入幅面 <A3>（A0~A4，加长如 A3X3）:"
			S_ORIENT:
				return "SHEET 横式还是竖式 [横(H)/竖(V)] <H>:"
			S_PROJECT:
				return "SHEET 输入工程名称（回车跳过）:"
			S_DRAWING:
				return "SHEET 输入图名（回车跳过）:"
			S_NUMBER:
				return "SHEET 输入图号（回车跳过）:"
		return ""

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_FORMAT:
				if t != "":
					if GbSheet.sheet_size(t).x <= 0.0:
						ctx.set_status("没有幅面「%s」，可选：%s" % [t, ", ".join(GbSheet.format_names())])
						return false
					_format = t.to_upper()
				_state = S_ORIENT
			S_ORIENT:
				_portrait = t.to_upper().begins_with("V") or t == "竖"
				_state = S_PROJECT
			S_PROJECT:
				_fields["project"] = t
				_state = S_DRAWING
			S_DRAWING:
				_fields["drawing"] = t
				_state = S_NUMBER
			S_NUMBER:
				_fields["number"] = t
				_build()
				return true
		ctx.set_status(prompt())
		return false

	func on_enter() -> bool:
		match _state:
			S_FORMAT:
				_state = S_ORIENT
			S_ORIENT:
				_state = S_PROJECT
			S_PROJECT:
				_state = S_DRAWING
			S_DRAWING:
				_state = S_NUMBER
			S_NUMBER:
				_build()
				return true
		ctx.set_status(prompt())
		return false

	## 生成图框后按出图比例整体放大
	func _build() -> void:
		_fields["scale"] = "1:%d" % int(ctx.doc.plot_scale)
		var before := ctx.doc.entity_count()
		if not GbSheet.build_frame(ctx.doc, _format, _portrait, _fields):
			ctx.set_status("幅面无效，图框未插入")
			ctx.doc.rollback_transaction()
			return
		var k := ctx.doc.plot_scale
		if absf(k - 1.0) > 1.0e-6:
			# 只对本次新增的图元做缩放，避免影响图纸上已有内容
			var added: Array[CadEntity] = []
			for i in range(before, ctx.doc.entity_count()):
				added.append(ctx.doc.entities[i])
			var xf := Transform2D(Vector2(k, 0.0), Vector2(0.0, k), Vector2.ZERO)
			for e in added:
				ctx.doc.mark_modified(e)
				e.transform_by(xf)
				ctx.doc.touch(e)
		ctx.doc.commit_transaction()
		ctx.set_status("已插入 %s 图框（按 1:%d 放大）" % [_format, int(k)])

	func cancel() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	func on_mouse_move(_p: Vector2) -> void:
		pass
