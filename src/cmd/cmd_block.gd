class_name CmdBlock
extends RefCounted
## 块命令：定义块、插入块、编辑属性。


class BlockBase extends CadCommand:
	func _begin(label: String) -> void:
		ctx.doc.begin_transaction(label)

	func _finish() -> void:
		ctx.doc.commit_transaction()
		ctx.set_status("")

	func _abort() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	func on_mouse_move(_p: Vector2) -> void:
		ctx.request_redraw()

	## 预览一个块引用的轮廓
	func _preview_insert(ci: CanvasItem, view: ViewTransform, ins: EntInsert) -> void:
		var col := Color(0.6, 0.9, 1.0, 0.9)
		for c in ins.get_curves():
			var pts := PackedVector2Array()
			for q in c.tessellate(view.sagitta_for_pixels(0.5)):
				pts.append(view.to_screen(q))
			if pts.size() >= 2:
				ci.draw_polyline(pts, col, 1.0, true)
		for a in ins.get_annotation_texts():
			ci.draw_string(ThemeDB.fallback_font, view.to_screen(a["position"]),
				String(a["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 1.0, 0.8))


# ===========================================================================
# 定义块
# ===========================================================================

class BlockCmd extends BlockBase:
	enum { S_SELECT, S_BASE, S_NAME, S_KEEP }
	var _state := S_SELECT
	var _base := Vector2.ZERO
	var _name := ""

	func cmd_name() -> String:
		return "BLOCK"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["b", "创建块"])

	func help_text() -> String:
		return "定义块：选择对象 -> 指定基点 -> 输入块名 -> 选择是否保留原对象"

	func is_selecting() -> bool:
		return _state == S_SELECT

	func start(_args: Dictionary) -> void:
		_begin("定义块")
		_state = S_SELECT
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_SELECT:
				return "BLOCK 选择要包含的对象（回车确认，已选 %d 个）:" % ctx.selection.size()
			S_BASE:
				return "BLOCK 指定块基点:"
			S_NAME:
				return "BLOCK 输入块名:"
			S_KEEP:
				return "BLOCK 是否保留原对象? [是(Y)/否(N)] <Y>:"
		return ""

	func on_enter() -> bool:
		match _state:
			S_SELECT:
				if ctx.selection.is_empty():
					ctx.set_status("未选择对象")
					_abort()
					return true
				_state = S_BASE
				ctx.set_status(prompt())
				return false
			S_KEEP:
				_finish_block(true)
				return true
		_abort()
		return true

	func on_point(p: Vector2) -> bool:
		if _state == S_BASE:
			_base = p
			_state = S_NAME
			ctx.set_status(prompt())
			return false
		return false

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_NAME:
				if t == "":
					return false
				_name = t
				# 块名已存在 -> 就是"重定义块"的用法（AutoCAD 的 BLOCK 行为）。
				# 这是编辑块的标准流程：分解引用 -> 改图元 -> 用同一个名字重建。
				if ctx.doc.blocks.has(_name):
					ctx.set_status("块「%s」已存在，将重定义并由 %d 处引用同步更新。" % [
						_name, _count_refs(_name)])
				_state = S_KEEP
				ctx.set_status(prompt())
				return false
			S_KEEP:
				_finish_block(not t.to_upper().begins_with("N"))
				return true
		return false

	## 统计某个块被多少处引用
	func _count_refs(name: String) -> int:
		var n := 0
		for e in ctx.doc.entities:
			if e is EntInsert and (e as EntInsert).block_name == name:
				n += 1
		return n


	func _finish_block(keep: bool) -> void:
		var blk := CadBlock.make(_name, _base)
		blk.builtin = false
		# 块内图元坐标改为相对基点
		var to_local := Transform2D(0.0, -_base)
		for e in ctx.selection.items:
			var c := e.clone()
			if c == null:
				continue
			c.handle = 0
			c.transform_by(to_local)
			blk.add(c)
		var redefine := ctx.doc.blocks.has(_name)
		var refs := _count_refs(_name)
		ctx.doc.blocks[_name] = blk
		# 重定义且已有引用时不再新增引用 —— 那些引用会自动指向新定义，
		# 用户是在"编辑块"，不是"再插一个"。
		# 块引用通过块名解析几何，因此无需逐个通知更新。
		if not (redefine and refs > 0):
			var ins := EntInsert.make(_name, _base)
			ins.layer = ctx.doc.current_layer
			ins.aci = ctx.doc.current_aci
			ctx.doc.add_entity(ins)
		if not keep:
			for e in ctx.selection.items:
				ctx.doc.remove_entity(e)
		ctx.selection.clear()
		ctx.doc.commit_transaction()
		if redefine:
			ctx.set_status("已重定义块「%s」（%d 个对象），%d 处引用已同步更新" % [
				_name, blk.entities.size(), refs])
		else:
			ctx.set_status("已定义块「%s」，含 %d 个对象" % [_name, blk.entities.size()])

	func cancel() -> void:
		_abort()


# ===========================================================================
# 插入块
# ===========================================================================

class InsertCmd extends BlockBase:
	enum { S_NAME, S_POS, S_SCALE, S_ROT }
	var _state := S_NAME
	var _name := ""
	var _scale := 1.0
	var _rot_deg := 0.0

	func cmd_name() -> String:
		return "INSERT"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["i", "ddinsert", "插入块"])

	func help_text() -> String:
		return "插入块：输入块名（L 列出全部）-> 插入点 -> 比例 -> 旋转角"

	func start(_args: Dictionary) -> void:
		_begin("插入块")
		_state = S_NAME
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_NAME:
				return "INSERT 输入块名（L 列出可用块，共 %d 个）:" % ctx.doc.blocks.size()
			S_POS:
				return "INSERT 指定插入点:"
			S_SCALE:
				return "INSERT 输入比例 <1>:"
			S_ROT:
				return "INSERT 输入旋转角 <0>:"
		return ""

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_NAME:
				if t.to_upper() == "L":
					ctx.set_status("可用块：" + ", ".join(_names()))
					return false
				if t == "":
					return false
				if not ctx.doc.blocks.has(t):
					var hit := _fuzzy(t)
					if hit == "":
						ctx.set_status("没有块「%s」，输入 L 可列出全部" % t)
						return false
					t = hit
				_name = t
				_state = S_POS
			S_SCALE:
				if t != "":
					_scale = maxf(t.to_float(), 1.0e-6)
				_state = S_ROT
			S_ROT:
				if t != "":
					_rot_deg = t.to_float()
				return false
		ctx.set_status(prompt())
		return false

	func _names() -> Array[String]:
		var out: Array[String] = []
		for k in ctx.doc.blocks.keys():
			out.append(String(k))
		out.sort()
		return out

	func _fuzzy(t: String) -> String:
		for n in _names():
			if n.to_lower().contains(t.to_lower()) or t.to_lower().contains(n.to_lower()):
				return n
		return ""

	func on_point(p: Vector2) -> bool:
		if _state == S_POS:
			var ins := EntInsert.make(_name, p)
			ins.scale = Vector2(_scale, _scale)
			ins.rotation = deg_to_rad(_rot_deg)
			ins.layer = ctx.doc.current_layer
			ins.aci = ctx.doc.current_aci
			# 属性块：用属性定义的默认值预填
			var blk := ctx.doc.get_block(_name)
			if blk != null:
				for a in blk.attribute_defs:
					var d: Dictionary = a
					ins.attributes[String(d.get("tag", ""))] = String(d.get("default", ""))
			ctx.doc.add_entity(ins)
			_finish()
			return true
		return false

	func on_enter() -> bool:
		match _state:
			S_SCALE:
				_state = S_ROT
				ctx.set_status(prompt())
				return false
			S_ROT:
				return false
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_POS:
			return
		var ins := EntInsert.make(_name, p)
		ins.scale = Vector2(_scale, _scale)
		ins.rotation = deg_to_rad(_rot_deg)
		_preview_insert(ci, view, ins)


# ===========================================================================
# 编辑属性
# ===========================================================================

class AttEdit extends BlockBase:
	enum { S_PICK, S_TAG, S_VALUE }
	var _state := S_PICK
	var _ins: EntInsert = null
	var _tags: Array[String] = []
	var _idx := 0
	var _pending_tag := ""

	func cmd_name() -> String:
		return "ATTEDIT"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["ate", "属性编辑"])

	func help_text() -> String:
		return "编辑属性：点取属性块 -> 依次为新值（回车保留当前值）"

	func start(args := {}) -> void:
		_begin("编辑属性")
		_state = S_PICK
		if args.has("entity"):
			_begin_edit(args["entity"])
		else:
			ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_PICK:
				return "ATTEDIT 选择属性块:"
			S_TAG:
				if _idx < _tags.size():
					return "ATTEDIT [%s] 输入新值 <当前：%s>:（回车跳过）" % [
						_tags[_idx], String(_ins.attributes.get(_tags[_idx], ""))]
				return ""
			S_VALUE:
				return "ATTEDIT 输入新值:"
		return ""

	func _begin_edit(e: CadEntity) -> void:
		if not (e is EntInsert):
			ctx.set_status("请选择块引用")
			return
		_ins = e as EntInsert
		var blk := ctx.doc.get_block(_ins.block_name)
		if blk == null or blk.attribute_defs.is_empty():
			ctx.set_status("块「%s」没有属性定义" % _ins.block_name)
			_abort()
			return
		_tags.clear()
		for a in blk.attribute_defs:
			_tags.append(String((a as Dictionary).get("tag", "")))
		_idx = 0
		_state = S_TAG
		ctx.set_status(prompt())

	func on_point(p: Vector2) -> bool:
		if _state != S_PICK:
			return false
		var tol := ctx.view.tolerance_for_pixels(8.0)
		var e := CadSelection.pick(ctx.doc, ctx.index, p, tol)
		if e == null:
			return false
		_begin_edit(e)
		return false

	func on_text(s: String) -> bool:
		if _state != S_TAG or _ins == null:
			return false
		var t := s.strip_edges()
		if t != "":
			ctx.doc.mark_modified(_ins)
			_ins.attributes[_tags[_idx]] = t
			ctx.doc.touch(_ins)
		_idx += 1
		if _idx >= _tags.size():
			_finish()
			return true
		ctx.set_status(prompt())
		return false

	func on_enter() -> bool:
		if _state == S_TAG and _ins != null:
			_idx += 1
			if _idx >= _tags.size():
				_finish()
				return true
			ctx.set_status(prompt())
			return false
		_abort()
		return true

	func cancel() -> void:
		_abort()
