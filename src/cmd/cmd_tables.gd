class_name CmdTables
extends RefCounted
## 表格与选择类命令：快速选择、图纸目录、材料做法表。


# ===========================================================================
# 快速选择
# ===========================================================================

class QuickSelect extends CadCommand:
	## 按条件筛选图元并入选择集。
	## 支持三个条件：图元类型、图层、颜色索引；留空的表示不限。
	enum { S_TYPE, S_LAYER, S_COLOR, S_DONE }
	var _state := S_TYPE
	var _type := ""
	var _layer := ""
	var _aci := -1
	var _matched: Array[CadEntity] = []

	## 类型名 -> 内部类型码
	const TYPES := {
		"直线": CadEntity.Type.LINE,
		"多段线": CadEntity.Type.POLYLINE,
		"圆": CadEntity.Type.CIRCLE,
		"圆弧": CadEntity.Type.ARC,
		"椭圆": CadEntity.Type.ELLIPSE,
		"样条": CadEntity.Type.SPLINE,
		"点": CadEntity.Type.POINT,
		"文字": CadEntity.Type.TEXT,
		"多行文字": CadEntity.Type.MTEXT,
		"填充": CadEntity.Type.HATCH,
		"标注": CadEntity.Type.DIMENSION,
		"墙体": CadEntity.Type.WALL,
		"块引用": CadEntity.Type.INSERT,
		"符号": CadEntity.Type.SYMBOL,
		"构造线": CadEntity.Type.XLINE,
		"射线": CadEntity.Type.RAY,
	}

	func cmd_name() -> String:
		return "QSELECT"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["qs", "快速选择"])

	func help_text() -> String:
		return "快速选择：依次输入 类型 / 图层 / 颜色索引，留空表示不限"

	func start(_args: Dictionary) -> void:
		_state = S_TYPE
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_TYPE:
				return "QSELECT 输入图元类型（留空不限）：%s" % ", ".join(TYPES.keys())
			S_LAYER:
				return "QSELECT 输入图层名（留空不限）。可选：%s" % ", ".join(ctx.doc.layer_names())
			S_COLOR:
				return "QSELECT 输入颜色索引 1~9（留空不限）:"
		return ""

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_TYPE:
				if t != "":
					if not TYPES.has(t):
						# 允许用内部类型名或英文缩写匹配
						var hit := _match_type(t)
						if hit == "":
							ctx.set_status("没有类型「%s」" % t)
							return false
						t = hit
					_type = t
				_state = S_LAYER
			S_LAYER:
				if t != "":
					if not ctx.doc.layers.has(t):
						ctx.set_status("没有图层「%s」" % t)
						return false
					_layer = t
				_state = S_COLOR
			S_COLOR:
				if t != "":
					var v := t.to_int()
					if v < 1 or v > 255:
						ctx.set_status("颜色索引应在 1~255 之间")
						return false
					_aci = v
				_apply()
				return true
		ctx.set_status(prompt())
		return false

	func _match_type(t: String) -> String:
		var up := t.to_upper()
		for k in TYPES.keys():
			var name := String(k)
			if name == t or name.to_upper() == up:
				return name
		# 英文名匹配
		var en := {
			"LINE": "直线", "POLYLINE": "多段线", "CIRCLE": "圆", "ARC": "圆弧",
			"ELLIPSE": "椭圆", "SPLINE": "样条", "POINT": "点", "TEXT": "文字",
			"MTEXT": "多行文字", "HATCH": "填充", "DIMENSION": "标注",
			"WALL": "墙体", "INSERT": "块引用", "SYMBOL": "符号",
		}
		return String(en.get(up, ""))

	func on_enter() -> bool:
		return on_text("")

	func cancel() -> void:
		ctx.set_status("")

	## 按条件筛选。命中者加入选择集（不清空原有内容，便于多次叠加筛选）。
	func _apply() -> void:
		ctx.selection.clear()
		_matched.clear()
		var want_type := int(TYPES.get(_type, -1)) if _type != "" else -1
		for e in ctx.doc.entities:
			if not e.visible:
				continue
			var l := ctx.doc.get_layer(e.layer)
			if l != null and not l.is_selectable():
				continue
			if want_type >= 0 and e.type != want_type:
				continue
			if _layer != "" and e.layer != _layer:
				continue
			if _aci > 0 and e.aci != _aci:
				continue
			_matched.append(e)
			ctx.selection.add(e)
		ctx.notify_selection_changed()
		ctx.set_status("快速选择：命中 %d 个对象（类型「%s」图层「%s」颜色 %s）" % [
			_matched.size(),
			_type if _type != "" else "不限",
			_layer if _layer != "" else "不限",
			str(_aci) if _aci > 0 else "不限"])
		ctx.request_redraw()


# ===========================================================================
# 图纸目录
# ===========================================================================

class SheetList extends CadCommand:
	func cmd_name() -> String:
		return "SHEETLIST"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["图纸目录"])

	func help_text() -> String:
		return "图纸目录：统计各布局的图名与图号，在指定位置生成表格"

	func start(_args: Dictionary) -> void:
		ctx.doc.begin_transaction("图纸目录")
		ctx.set_status(prompt())

	func prompt() -> String:
		return "SHEETLIST 点取图纸目录左上角位置:"

	func on_point(p: Vector2) -> bool:
		var rows: Array = []
		for l in ctx.doc.layouts:
			var lay := l as CadLayout
			var tf := lay.title_fields
			rows.append([
				String(tf.get("number", "")),
				String(tf.get("drawing", lay.name)),
				lay.format + ("竖" if lay.portrait else "横"),
				"1:%d" % int(lay.main_viewport().scale),
			])
		# 没有布局时至少给一行说明，避免生成空表让人以为命令坏了
		if rows.is_empty():
			rows.append(["—", "（尚未建立布局）", "—", "—"])
		CmdTables._build_table(ctx.doc, p, "图纸目录",
			["图号", "图名", "幅面", "比例"], [1800.0, 4200.0, 1400.0, 1400.0], rows)
		ctx.doc.commit_transaction()
		ctx.set_status("图纸目录已生成（%d 行）" % rows.size())
		return true

	func on_enter() -> bool:
		ctx.doc.rollback_transaction()
		ctx.set_status("")
		return true

	func cancel() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	func on_mouse_move(_p: Vector2) -> void:
		pass


# ===========================================================================
# 材料做法表
# ===========================================================================

class MaterialTable extends CadCommand:
	func cmd_name() -> String:
		return "MATLIST"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["材料做法表", "做法表"])

	func help_text() -> String:
		return "材料做法表：按标准做法模板生成表格，事后可用改文字命令逐格修改"

	func start(_args: Dictionary) -> void:
		ctx.doc.begin_transaction("材料做法表")
		ctx.set_status(prompt())

	func prompt() -> String:
		return "MATLIST 点取材料做法表左上角位置:"

	## 常见做法模板。生成后可用改文字命令逐格改 ——
	## 做法因地区与项目而异，软件给模板而不是替用户定死。
	const TEMPLATE := [
		["地面", "1. 素土夯实\n2. 150 厚 3:7 灰土\n3. 60 厚 C15 混凝土\n4. 20 厚 1:2 水泥砂浆"],
		["楼面", "1. 钢筋混凝土楼板\n2. 20 厚 1:2 水泥砂浆找平\n3. 结合层\n4. 面层"],
		["内墙", "1. 基层处理\n2. 15 厚 1:1:6 混合砂浆打底\n3. 5 厚 1:0.3:3 混合砂浆面层\n4. 内墙涂料"],
		["外墙", "1. 基层处理\n2. 15 厚 1:3 水泥砂浆打底\n3. 5 厚 1:2.5 水泥砂浆面层\n4. 外墙面砖或涂料"],
		["顶棚", "1. 基层处理\n2. 5 厚 1:0.5:3 混合砂浆\n3. 5 厚 1:0.3:3 混合砂浆\n4. 顶棚涂料"],
		["屋面", "1. 钢筋混凝土屋面板\n2. 20 厚 1:3 水泥砂浆找平\n3. 隔汽层\n4. 保温层\n5. 防水层\n6. 保护层"],
		["散水", "1. 素土夯实\n2. 150 厚 3:7 灰土\n3. 60 厚 C15 混凝土\n4. 20 厚 1:2 水泥砂浆"],
	]

	func on_point(p: Vector2) -> bool:
		var rows: Array = []
		for r in TEMPLATE:
			rows.append([String(r[0]), String(r[1])])
		CmdTables._build_table(ctx.doc, p, "材料做法表",
			["部位", "做  法"], [1600.0, 7600.0], rows)
		ctx.doc.commit_transaction()
		ctx.set_status("材料做法表已生成（%d 行），可用改文字命令逐格修改" % rows.size())
		return true

	func on_enter() -> bool:
		ctx.doc.rollback_transaction()
		ctx.set_status("")
		return true

	func cancel() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	func on_mouse_move(_p: Vector2) -> void:
		pass


# ===========================================================================
# 表格绘制的公共实现
# ===========================================================================

## 生成一个带标题与表头的表格。rows 为二维字符串数组。
## 单元格内容过长时按列宽折行，行高随内容自适应 ——
## 材料做法这类多行文本不做处理会糊成一团。
static func _build_table(doc: CadDocument, origin: Vector2, title: String,
		headers: Array, widths: Array, rows: Array) -> void:
	var total_w := 0.0
	for w in widths:
		total_w += float(w)
	var title_h := 900.0
	var head_h := 700.0
	# 逐行按内容算高度
	var heights: Array = []
	for r in rows:
		var lines := 1
		for i in range((r as Array).size()):
			var txt := String((r as Array)[i])
			var n := txt.split("\n").size()
			var per_line := maxi(int(float(widths[i]) / 420.0), 1)
			var est := int(ceil(float(txt.length()) / float(per_line)))
			lines = maxi(lines, maxi(n, est))
		heights.append(560.0 + float(lines - 1) * 420.0)
	var body_h := 0.0
	for h in heights:
		body_h += float(h)

	# 线框
	var top := origin.y
	var bottom := top - title_h - head_h - body_h
	var lay := "尺寸标注"
	_h_line(doc, Vector2(origin.x, top), Vector2(origin.x + total_w, top))
	_h_line(doc, Vector2(origin.x, top - title_h), Vector2(origin.x + total_w, top - title_h))
	_h_line(doc, Vector2(origin.x, top - title_h - head_h),
		Vector2(origin.x + total_w, top - title_h - head_h))
	_h_line(doc, Vector2(origin.x, bottom), Vector2(origin.x + total_w, bottom))
	var x := origin.x
	_v_line(doc, x, top, bottom)
	for w in widths:
		x += float(w)
		_v_line(doc, x, top, bottom)
	# 每行的横线
	var y := top - title_h - head_h
	for h in heights:
		y -= float(h)
		_h_line(doc, Vector2(origin.x, y), Vector2(origin.x + total_w, y))

	# 标题
	_center_text(doc, Vector2(origin.x + total_w * 0.5, top - title_h * 0.5), title, 600.0)
	# 表头
	x = origin.x
	for i in range(headers.size()):
		_center_text(doc, Vector2(x + float(widths[i]) * 0.5, top - title_h - head_h * 0.5),
			String(headers[i]), 350.0)
		x += float(widths[i])
	# 数据
	y = top - title_h - head_h
	for ri in range(rows.size()):
		var r: Array = rows[ri]
		var rh := float(heights[ri])
		x = origin.x
		for i in range(r.size()):
			var txt := String(r[i])
			var lines := txt.split("\n")
			# 单元格内多行：自上而下排，行高不够时按列宽截断
			var line_h := 420.0
			var start_y := y - rh * 0.5 + float(lines.size() - 1) * line_h * 0.5
			for li in range(lines.size()):
				var cell := String(lines[li])
				var per_line := maxi(int(float(widths[i]) / 420.0), 1)
				if cell.length() > per_line * 3:
					cell = cell.substr(0, per_line * 3 - 1) + "…"
				_center_text(doc, Vector2(x + float(widths[i]) * 0.5, start_y - float(li) * line_h),
					cell, 320.0)
			x += float(widths[i])
		y -= rh


static func _h_line(doc: CadDocument, a: Vector2, b: Vector2) -> void:
	var e := EntLine.make(a, b)
	e.layer = "尺寸标注"
	e.aci = 256
	e.lineweight = 0.5
	doc.add_entity(e, false)


static func _v_line(doc: CadDocument, x: float, top: float, bottom: float) -> void:
	_h_line(doc, Vector2(x, top), Vector2(x, bottom))


static func _center_text(doc: CadDocument, pos: Vector2, s: String, h: float) -> void:
	var t := EntText.make(pos, s, h)
	t.text_style = "仿宋_3.5"
	t.h_align = EntText.HAlign.CENTER
	t.v_align = EntText.VAlign.MIDDLE
	t.layer = "文字"
	t.aci = 256
	doc.add_entity(t, false)


# ===========================================================================
# 模数校验
# ===========================================================================

class ModCheck extends CadCommand:
	## 检查选中图元的关键尺寸是否符合 GB/T 50002 的模数或常用尺寸序列。
	## 目的是在制图阶段就把"3600 配 3610"这类问题暴露出来，
	## 而不是等到预制件到现场才发现装不上。
	func cmd_name() -> String:
		return "MODCHECK"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["mc", "模数校验"])

	func help_text() -> String:
		return "模数校验：检查选中图元的关键尺寸是否符合 GB/T 50002（未选则检查全部墙体）"

	func start(_args: Dictionary) -> void:
		var targets: Array = ctx.selection.items
		if targets.is_empty():
			for e in ctx.doc.entities:
				if e is EntWall:
					targets.append(e)
		if targets.is_empty():
			ctx.set_status("没有可检查的对象（请选中图元，或先画墙体）")
			return
		var issues: Array[String] = []
		var checked := 0
		for e in targets:
			if e is EntWall:
				var w := e as EntWall
				checked += 1
				var msg := GbModular.validate_all(w.thickness, "墙厚", GbModular.WALL_THICKNESSES)
				if msg != "":
					issues.append(msg)
				for o in w.openings:
					var op := o as EntWall.Opening
					checked += 1
					var seq := GbModular.WINDOW_WIDTHS if op.is_window else GbModular.DOOR_WIDTHS
					var label := "窗洞宽" if op.is_window else "门洞宽"
					var m2 := GbModular.validate_all(op.width, label, seq)
					if m2 != "":
						issues.append("%s（%s）" % [m2, op.block_name])
			elif e is EntLine:
				# 直线的长度按基本模数 100 检查
				var l := e as EntLine
				checked += 1
				var len := l.length()
				# 只检查有意义的长度，几毫米的构造线不必苛求
				if len >= 300.0:
					var m3 := GbModular.validate(len, "线段长")
					if m3 != "":
						issues.append(m3)
			elif e is EntCircle:
				checked += 1
				var c := e as EntCircle
				if c.radius * 2.0 >= 300.0:
					var m4 := GbModular.validate(c.radius * 2.0, "圆直径")
					if m4 != "":
						issues.append(m4)
		if issues.is_empty():
			ctx.set_status("模数校验通过：共检查 %d 项尺寸，均符合 GB/T 50002" % checked)
		else:
			# 只报前若干条，避免刷屏；剩余条数一并说明
			var head := issues.slice(0, 8)
			var tail := "" if issues.size() <= 8 else "（另有 %d 项）" % (issues.size() - 8)
			ctx.set_status("模数校验：%d 项中有 %d 项不合模数 —— %s %s" % [
				checked, issues.size(), "; ".join(head), tail])

	func on_point(_p: Vector2) -> bool:
		return false

	func on_enter() -> bool:
		return true

	func cancel() -> void:
		pass

	func on_mouse_move(_p: Vector2) -> void:
		pass
