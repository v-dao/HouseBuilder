class_name LayerPanel
extends VBoxContainer
## 图层管理器。
##
## 图层的可见/冻结/锁定是制图时最频繁的操作，因此做成一览式的勾选表格，
## 而不是藏在对话框里。当前层用加粗标记，点「置为当前」切换。
##
## 国标 GB/T 50001 对图层管理有专门要求（"计算机制图文件与图层管理"），
## 核心是图层名与线宽、线型的对应关系 —— 这里把三者放在一行，便于核对。

signal changed()

var doc: CadDocument = null

var _list: VBoxContainer
var _rows: Array = []
var _name_edit: LineEdit
var _hint: Label


func _ready() -> void:
	add_theme_constant_override("separation", 4)

	var title := Label.new()
	title.text = "图层"
	title.add_theme_font_size_override("font_size", 14)
	add_child(title)

	# 表头
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 2)
	head.add_child(_head_cell("名称", 108))
	head.add_child(_head_cell("显", 24))
	head.add_child(_head_cell("冻", 24))
	head.add_child(_head_cell("锁", 24))
	head.add_child(_head_cell("线宽", 44))
	add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 160)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	# 新建图层
	var row := HBoxContainer.new()
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "新图层名"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_name_edit)
	var add_btn := Button.new()
	add_btn.text = "新建"
	add_btn.focus_mode = Control.FOCUS_NONE
	add_btn.pressed.connect(_on_add_layer)
	row.add_child(add_btn)
	add_child(row)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.text = "点行名设为当前层；显/冻/锁 为可见、冻结、锁定。"
	add_child(_hint)


func _head_cell(text: String, w: int) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(w, 0)
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.62, 0.70, 0.80))
	return l


func setup(p_doc: CadDocument) -> void:
	doc = p_doc
	refresh()


func refresh() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	_rows.clear()
	if doc == null:
		return
	for name in doc.layer_names():
		var l: CadLayer = doc.layers[name]
		_list.add_child(_make_row(l))


func _make_row(l: CadLayer) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)

	# 名称按钮：点一下设为当前层。色块直接画在文字前，一眼看出图层颜色
	var is_current := (l.name == doc.current_layer)
	var nb := Button.new()
	nb.text = ("● " if is_current else "   ") + l.name
	nb.custom_minimum_size = Vector2(108, 0)
	nb.focus_mode = Control.FOCUS_NONE
	nb.tooltip_text = "%s\n线型 %s，线宽 %s\n%s" % [
		l.name, l.linetype,
		("随默认" if l.lineweight < 0.0 else "%.3fmm" % l.lineweight),
		l.description]
	nb.add_theme_font_size_override("font_size", 11)
	nb.add_theme_color_override("font_color", l.color)
	nb.pressed.connect(func() -> void:
		doc.current_layer = l.name
		refresh()
		changed.emit())
	row.add_child(nb)

	row.add_child(_check(l.visible, func(v: bool) -> void:
		l.visible = v
		_emit()))
	row.add_child(_check(l.frozen, func(v: bool) -> void:
		l.frozen = v
		_emit()))
	row.add_child(_check(l.locked, func(v: bool) -> void:
		l.locked = v
		_emit()))

	# 线宽用下拉，只给国标线宽组的取值
	var lw := OptionButton.new()
	lw.custom_minimum_size = Vector2(44, 0)
	lw.add_theme_font_size_override("font_size", 10)
	var opts := [-3.0, -1.0, 0.13, 0.18, 0.25, 0.35, 0.5, 0.7, 1.0, 1.4]
	var labels := ["默认", "随层", "0.13", "0.18", "0.25", "0.35", "0.5", "0.7", "1.0", "1.4"]
	var sel := 0
	for i in range(opts.size()):
		lw.add_item(labels[i], i)
		if absf(opts[i] - l.lineweight) < 1e-6:
			sel = i
	lw.select(sel)
	lw.item_selected.connect(func(idx: int) -> void:
		l.lineweight = float(opts[idx])
		_emit())
	row.add_child(lw)
	return row


func _check(on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.button_pressed = on
	c.focus_mode = Control.FOCUS_NONE
	c.custom_minimum_size = Vector2(24, 0)
	c.toggled.connect(cb)
	return c


func _emit() -> void:
	# 图层属性变化必须让文档版本号递增，否则渲染缓存不会失效
	if doc != null:
		doc.bump()
	refresh()
	changed.emit()


func _on_add_layer() -> void:
	var n := _name_edit.text.strip_edges()
	if n == "" or doc == null:
		return
	if doc.layers.has(n):
		_hint.text = "图层「%s」已存在" % n
		return
	# 新图层按国标线宽组的细线起步，颜色给固定的白
	doc.layers[n] = CadLayer.make(n, Color.WHITE, 7, "CONTINUOUS", 0.25, "新建图层")
	doc.current_layer = n
	doc.bump()
	_name_edit.text = ""
	_hint.text = "已新建图层「%s」" % n
	refresh()
	changed.emit()
