class_name PropertyPanel
extends VBoxContainer
## 特性面板。
##
## 显示并编辑当前选择集的公共属性（图层/颜色/线型/线宽），
## 以及单选时的几何参数。
##
## 编辑一律走文档事务，因此特性面板里的每次改动都能撤销 ——
## 这一点与命令行里改参数是同一套机制，不存在"从面板改的撤不掉"。

signal changed()

var doc: CadDocument = null
var viewport: CadViewport = null

var _title: Label
var _empty: Label
var _body: VBoxContainer
## 防止程序化刷新时回写触发递归
var _updating := false


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_title = Label.new()
	_title.text = "特性"
	_title.add_theme_font_size_override("font_size", 14)
	add_child(_title)

	_empty = Label.new()
	_empty.text = "未选择对象"
	_empty.add_theme_font_size_override("font_size", 11)
	_empty.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	add_child(_empty)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 200)
	add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_body)


func setup(p_doc: CadDocument, p_viewport: CadViewport) -> void:
	doc = p_doc
	viewport = p_viewport
	refresh()


func refresh() -> void:
	if _body == null:
		return
	_updating = true
	for c in _body.get_children():
		c.queue_free()
	var sel: Array = viewport.selection_items() if viewport != null else []
	_empty.visible = sel.is_empty()
	if sel.is_empty():
		_title.text = "特性"
		_updating = false
		return

	# 公共属性
	_title.text = "特性（已选 %d 个）" % sel.size()
	var first: CadEntity = sel[0]
	var types := {}
	for e in sel:
		types[(e as CadEntity).type_name()] = true
	if types.size() == 1:
		_body.add_child(_row_label("类型", String(types.keys()[0])))
	else:
		_body.add_child(_row_label("类型", "多种（%d 类）" % types.size()))

	_body.add_child(_layer_row(sel))
	_body.add_child(_aci_row(sel))
	_body.add_child(_linetype_row(sel))
	_body.add_child(_lineweight_row(sel))

	# 单选时给出几何参数
	if sel.size() == 1:
		var geo := _geometry_rows(first)
		if geo.size() > 0:
			_body.add_child(_separator())
			for r in geo:
				_body.add_child(r)
	_updating = false


# ---------------------------------------------------------------------------
# 行构造
# ---------------------------------------------------------------------------

func _row_label(k: String, v: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	var a := Label.new()
	a.text = k
	a.custom_minimum_size = Vector2(64, 0)
	a.add_theme_font_size_override("font_size", 11)
	h.add_child(a)
	var b := Label.new()
	b.text = v
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 11)
	h.add_child(b)
	return h


func _separator() -> HSeparator:
	return HSeparator.new()


func _row_control(k: String, c: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	var a := Label.new()
	a.text = k
	a.custom_minimum_size = Vector2(64, 0)
	a.add_theme_font_size_override("font_size", 11)
	h.add_child(a)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(c)
	return h


func _layer_row(sel: Array) -> HBoxContainer:
	var opt := OptionButton.new()
	opt.add_theme_font_size_override("font_size", 11)
	var names := doc.layer_names()
	var same := _common_string(sel, func(e: CadEntity) -> String: return e.layer)
	var idx := 0
	if same == "":
		opt.add_item("多种", 0)
	for i in range(names.size()):
		opt.add_item(names[i], i + 1)
		if names[i] == same:
			idx = i + 1
	opt.select(idx)
	opt.item_selected.connect(func(i: int) -> void:
		if _updating or i == 0:
			return
		_apply(sel, func(e: CadEntity) -> void: e.layer = names[i - 1]))
	return _row_control("图层", opt)


func _aci_row(sel: Array) -> HBoxContainer:
	# 颜色只给"随层"与 ACI 1~9，覆盖国标图层的常用取值
	var opt := OptionButton.new()
	opt.add_theme_font_size_override("font_size", 11)
	var labels := ["随层", "红", "黄", "绿", "青", "蓝", "洋红", "白", "深灰", "浅灰"]
	var acis := [256, 1, 2, 3, 4, 5, 6, 7, 8, 9]
	for i in range(labels.size()):
		opt.add_item(labels[i], i)
	var same := _common_int(sel, func(e: CadEntity) -> int: return e.aci)
	var idx := 0
	for i in range(acis.size()):
		if acis[i] == same:
			idx = i
	opt.select(idx)
	opt.item_selected.connect(func(i: int) -> void:
		if _updating:
			return
		var aci_v := int(acis[i])
		_apply(sel, func(e: CadEntity) -> void:
			e.aci = aci_v
			if aci_v >= 1 and aci_v <= 9:
				e.color = DxfReader._aci_color(aci_v)))
	return _row_control("颜色", opt)


func _linetype_row(sel: Array) -> HBoxContainer:
	var opt := OptionButton.new()
	opt.add_theme_font_size_override("font_size", 11)
	var names: Array[String] = ["随层", "CONTINUOUS", "DASHED", "CENTER", "PHANTOM"]
	var vals := ["BYLAYER", "CONTINUOUS", "DASHED", "CENTER", "PHANTOM"]
	for i in range(names.size()):
		opt.add_item(names[i], i)
	var same := _common_string(sel, func(e: CadEntity) -> String: return e.linetype)
	var idx := 0
	for i in range(vals.size()):
		if vals[i] == same:
			idx = i
	opt.select(idx)
	opt.item_selected.connect(func(i: int) -> void:
		if _updating:
			return
		var v: String = vals[i]
		_apply(sel, func(e: CadEntity) -> void: e.linetype = v))
	return _row_control("线型", opt)


func _lineweight_row(sel: Array) -> HBoxContainer:
	var opt := OptionButton.new()
	opt.add_theme_font_size_override("font_size", 11)
	var labels := ["随层", "默认", "0.13", "0.18", "0.25", "0.35", "0.5", "0.7", "1.0", "1.4"]
	var vals := [CadLayer.LW_BYLAYER, CadLayer.LW_DEFAULT, 0.13, 0.18, 0.25, 0.35, 0.5, 0.7, 1.0, 1.4]
	for i in range(labels.size()):
		opt.add_item(labels[i], i)
	var same := _common_float(sel, func(e: CadEntity) -> float: return e.lineweight)
	var idx := 0
	for i in range(vals.size()):
		if absf(float(vals[i]) - same) < 1e-6:
			idx = i
	opt.select(idx)
	opt.item_selected.connect(func(i: int) -> void:
		if _updating:
			return
		var v := float(vals[i])
		_apply(sel, func(e: CadEntity) -> void: e.lineweight = v))
	return _row_control("线宽", opt)


## 单选时的几何参数。只读展示为主，路径类给可编辑的坐标输入。
func _geometry_rows(e: CadEntity) -> Array:
	var out: Array = []
	if e is EntLine:
		var l := e as EntLine
		out.append(_vec_row("起点", l, l.p0, func(x: CadEntity, v: Vector2) -> void: (x as EntLine).p0 = v))
		out.append(_vec_row("终点", l, l.p1, func(x: CadEntity, v: Vector2) -> void: (x as EntLine).p1 = v))
		out.append(_row_label("长度", "%.1f" % l.length()))
	elif e is EntCircle:
		var c := e as EntCircle
		out.append(_vec_row("圆心", c, c.center, func(x: CadEntity, v: Vector2) -> void: (x as EntCircle).center = v))
		out.append(_num_row("半径", c, c.radius, func(x: CadEntity, v: float) -> void: (x as EntCircle).radius = maxf(v, Tol.MIN_RADIUS)))
	elif e is EntArc:
		var a := e as EntArc
		out.append(_vec_row("圆心", a, a.center, func(x: CadEntity, v: Vector2) -> void: (x as EntArc).center = v))
		out.append(_num_row("半径", a, a.radius, func(x: CadEntity, v: float) -> void: (x as EntArc).radius = maxf(v, Tol.MIN_RADIUS)))
		out.append(_row_label("起始角", "%.1f°" % rad_to_deg(a.start_angle)))
		out.append(_row_label("终止角", "%.1f°" % rad_to_deg(a.end_angle)))
	elif e is EntText:
		var t := e as EntText
		var le := LineEdit.new()
		le.text = t.text
		le.add_theme_font_size_override("font_size", 11)
		le.text_submitted.connect(func(s: String) -> void:
			_apply([e], func(x: CadEntity) -> void:
				(x as EntText).text = s
				(x as EntText).measured_valid = false))
		out.append(_row_control("内容", le))
		out.append(_num_row("字高", t, t.height, func(x: CadEntity, v: float) -> void: (x as EntText).height = maxf(v, 0.1)))
		out.append(_vec_row("位置", t, t.position, func(x: CadEntity, v: Vector2) -> void: (x as EntText).position = v))
	elif e is EntWall:
		var w := e as EntWall
		out.append(_num_row("墙厚", w, w.thickness, func(x: CadEntity, v: float) -> void: (x as EntWall).thickness = maxf(v, 10.0)))
		out.append(_row_label("中心线长", "%.0f" % w._centerline_length()))
		out.append(_row_label("洞口数", str(w.openings.size())))
		out.append(_row_label("墙体面积", "%.2f m²" % (w.wall_area() / 1000000.0)))
	elif e is EntDim:
		out.append(_row_label("实测值", "%.1f" % (e as EntDim).measured_value()))
		out.append(_row_label("显示文字", (e as EntDim).display_text()))
	elif e is EntHatch:
		var h := e as EntHatch
		out.append(_row_label("图例", h.pattern_name))
		out.append(_row_label("实心", "是" if h.is_solid() else "否"))
		out.append(_row_label("线段数", str(h.pattern_segments().size() / 2)))
	elif e is EntInsert:
		var ins := e as EntInsert
		out.append(_row_label("块名", ins.block_name))
		out.append(_row_label("比例", "%.3f" % ins.scale.x))
		out.append(_row_label("旋转", "%.1f°" % rad_to_deg(ins.rotation)))
		for k in ins.attributes.keys():
			out.append(_row_label(String(k), String(ins.attributes[k])))
	elif e is EntPolyline:
		var p := e as EntPolyline
		out.append(_row_label("顶点数", str(p.points().size())))
		out.append(_row_label("闭合", "是" if p.is_closed() else "否"))
		out.append(_row_label("长度", "%.1f" % p.poly.curve_length()))
	return out


## 坐标输入行。编辑经由 _apply 提交，因此与命令行改参数一样可以撤销。
func _vec_row(k: String, e: CadEntity, v: Vector2, cb: Callable) -> HBoxContainer:
	var le := LineEdit.new()
	le.text = "%.1f, %.1f" % [v.x, v.y]
	le.add_theme_font_size_override("font_size", 11)
	le.tooltip_text = "格式：x, y（模型单位 mm）"
	le.text_submitted.connect(func(s: String) -> void:
		var parts := s.split(",")
		if parts.size() != 2:
			return
		var pv := Vector2(parts[0].strip_edges().to_float(), parts[1].strip_edges().to_float())
		_apply([e], func(x: CadEntity) -> void: cb.call(x, pv))
		refresh())
	return _row_control(k, le)


## 数值输入行。同样走事务。
func _num_row(k: String, e: CadEntity, v: float, cb: Callable) -> HBoxContainer:
	var le := LineEdit.new()
	le.text = "%.3f" % v
	le.add_theme_font_size_override("font_size", 11)
	le.text_submitted.connect(func(s: String) -> void:
		_apply([e], func(x: CadEntity) -> void: cb.call(x, s.strip_edges().to_float()))
		refresh())
	return _row_control(k, le)


# ---------------------------------------------------------------------------
# 应用改动（走事务，保证可撤销）
# ---------------------------------------------------------------------------

func _apply(sel: Array, fn: Callable) -> void:
	if doc == null or viewport == null or sel.is_empty():
		return
	doc.begin_transaction("修改特性")
	for e in sel:
		doc.mark_modified(e)
		fn.call(e)
		doc.touch(e)
	doc.commit_transaction()
	viewport.queue_redraw()
	changed.emit()


# ---------------------------------------------------------------------------
# 共性取值
# ---------------------------------------------------------------------------

func _common_string(sel: Array, getter: Callable) -> String:
	var v := ""
	for e in sel:
		var s: String = getter.call(e)
		if v == "":
			v = s
		elif v != s:
			return ""
	return v


func _common_int(sel: Array, getter: Callable) -> int:
	var v := -99999
	for e in sel:
		var s: int = getter.call(e)
		if v == -99999:
			v = s
		elif v != s:
			return -99999
	return v


func _common_float(sel: Array, getter: Callable) -> float:
	var v := -99999.0
	for e in sel:
		var s: float = getter.call(e)
		if v == -99999.0:
			v = s
		elif absf(v - s) > 1e-6:
			return -99999.0
	return v
