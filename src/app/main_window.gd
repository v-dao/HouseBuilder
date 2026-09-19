extends Control
## 主窗口。组装界面骨架：工具栏 + 绘图区 + 命令行 + 状态栏。
##
## 界面用代码构建而不是 .tscn，原因是布局逻辑（按钮与命令的绑定、
## 状态联动）本身就是代码，写在同一个文件里比散落在场景文件里更好维护。

var doc: CadDocument = null
var viewport: CadViewport = null
var cmd_edit: LineEdit = null
var prompt_label: Label = null
var coord_label: Label = null
var scale_label: Label = null
var count_label: Label = null
var sel_label: Label = null
var stat_label: Label = null
var grid_check: CheckBox = null
var lw_check: CheckBox = null
var cross_check: CheckBox = null
var osnap_check: CheckBox = null
var ortho_check: CheckBox = null
var grid_snap_check: CheckBox = null
var polar_check: CheckBox = null


func _ready() -> void:
	_build_ui()
	new_document()
	# 首次打开直接给一张示例图，让用户立刻看到软件能画出什么。
	# "新建" 会回到空白图纸。
	load_demo()
	# 预热字形图集（动态字体的图集是延迟生成的）
	FontManager.instance().warm_up()


# ---------------------------------------------------------------------------
# 界面构建
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_toolbar())

	viewport = CadViewport.new()
	viewport.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewport.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport.cursor_moved.connect(_on_cursor_moved)
	viewport.command_prompt_changed.connect(_on_prompt_changed)
	viewport.selection_changed.connect(_on_selection_changed)
	viewport.command_started.connect(func(n: String) -> void:
		prompt_label.text = CommandRegistry.help_for(n))
	viewport.command_finished.connect(func() -> void: _refresh_status())
	# F3/F8/F9/F10 在视口里切换状态，界面上的勾选要跟着同步
	viewport.snap_changed.connect(func() -> void:
		if osnap_check != null:
			osnap_check.set_pressed_no_signal(viewport.snap.osnap_enabled)
			ortho_check.set_pressed_no_signal(viewport.snap.ortho)
			grid_snap_check.set_pressed_no_signal(viewport.snap.grid_snap)
			polar_check.set_pressed_no_signal(viewport.snap.polar_enabled))
	root.add_child(viewport)

	root.add_child(_build_command_line())
	root.add_child(_build_status_bar())


func _build_toolbar() -> Control:
	var panel := PanelContainer.new()
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	panel.add_child(hb)

	hb.add_child(_file_menu())
	hb.add_child(VSeparator.new())
	hb.add_child(_btn("新建", func() -> void: new_document()))
	hb.add_child(_btn("示例图", func() -> void: load_demo()))
	hb.add_child(VSeparator.new())
	hb.add_child(_btn("撤销", func() -> void: _do_undo()))
	hb.add_child(_btn("重做", func() -> void: _do_redo()))
	hb.add_child(VSeparator.new())
	# 绘图/修改菜单由命令注册表生成，注册表里加命令会自动出现在此处
	hb.add_child(_cmd_menu("绘图", ["绘制"]))
	hb.add_child(_cmd_menu("修改", ["编辑", "几何编辑"]))
	hb.add_child(_cmd_menu("标注", ["标注"]))
	hb.add_child(_cmd_menu("符号", ["符号"]))
	hb.add_child(_cmd_menu("块", ["块"]))
	hb.add_child(_cmd_menu("建筑", ["建筑"]))
	hb.add_child(VSeparator.new())
	hb.add_child(_btn("删除", func() -> void: viewport.delete_selection()))
	hb.add_child(_btn("全选", func() -> void: viewport.select_all()))
	hb.add_child(VSeparator.new())
	hb.add_child(_btn("缩放全图", func() -> void: viewport.zoom_extents()))
	hb.add_child(VSeparator.new())

	grid_check = CheckBox.new()
	grid_check.text = "栅格"
	grid_check.button_pressed = true
	grid_check.toggled.connect(func(v: bool) -> void:
		viewport.show_grid = v
		viewport.queue_redraw())
	hb.add_child(grid_check)

	cross_check = CheckBox.new()
	cross_check.text = "十字光标"
	cross_check.button_pressed = true
	cross_check.toggled.connect(func(v: bool) -> void:
		viewport.show_crosshair = v
		viewport.queue_redraw())
	hb.add_child(cross_check)

	lw_check = CheckBox.new()
	lw_check.text = "显示线宽"
	lw_check.button_pressed = false
	lw_check.tooltip_text = "按国标线宽体系显示（1.0 / 0.7 / 0.5 / 0.25 b）"
	lw_check.toggled.connect(func(v: bool) -> void:
		viewport.renderer.show_lineweight = v
		viewport.queue_redraw())
	hb.add_child(lw_check)

	hb.add_child(VSeparator.new())
	osnap_check = _snap_check("对象捕捉 F3", func(v: bool) -> void: viewport.snap.osnap_enabled = v, true)
	hb.add_child(osnap_check)
	ortho_check = _snap_check("正交 F8", func(v: bool) -> void: viewport.snap.ortho = v, false)
	hb.add_child(ortho_check)
	grid_snap_check = _snap_check("栅格捕捉 F9", func(v: bool) -> void: viewport.snap.grid_snap = v, false)
	hb.add_child(grid_snap_check)
	polar_check = _snap_check("极轴 F10", func(v: bool) -> void: viewport.snap.polar_enabled = v, false)
	hb.add_child(polar_check)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)

	hb.add_child(_btn("帮助", func() -> void: _toggle_help()))
	return panel


## 捕捉类开关。点击后同步刷新视口，并按 F 键也能切换状态。
func _snap_check(label: String, cb: Callable, on: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = label
	c.focus_mode = Control.FOCUS_NONE
	c.button_pressed = on
	c.toggled.connect(func(v: bool) -> void:
		cb.call(v)
		viewport.queue_redraw())
	return c


## 文件菜单
func _file_menu() -> MenuButton:
	var mb := MenuButton.new()
	mb.text = "文件"
	mb.focus_mode = Control.FOCUS_NONE
	var pop := mb.get_popup()
	pop.add_item("打开工程 (Ctrl+O)", 0)
	pop.add_item("保存 (Ctrl+S)", 1)
	pop.add_item("另存为…", 2)
	pop.add_separator()
	pop.add_item("导出 DXF（R12，供 CAD 交换）", 3)
	pop.add_item("导出 SVG 矢量图", 4)
	pop.add_item("导出 PNG 光栅图", 5)
	pop.add_item("插入国标图框", 6)
	pop.id_pressed.connect(func(id: int) -> void: _on_file_menu(id))
	return mb


func _on_file_menu(id: int) -> void:
	match id:
		0:
			_open_dialog(FileDialog.FILE_MODE_OPEN_FILE, ["*.hbd"], "打开工程", _do_open)
		1:
			if _current_path == "":
				_open_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.hbd"], "保存工程", _do_save)
			else:
				_save_to(_current_path)
		2:
			_open_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.hbd"], "另存为", _do_save)
		3:
			_open_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.dxf"], "导出 DXF", _do_export_dxf)
		4:
			_open_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.svg"], "导出 SVG", _do_export_svg)
		5:
			_open_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.png"], "导出 PNG", _do_export_png)
		6:
			viewport.run_command("SHEET")


var _current_path: String = ""
var _dialog: FileDialog = null
var _dialog_cb: Callable = Callable()


func _open_dialog(mode: int, filters: Array, title: String, cb: Callable) -> void:
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = FileDialog.new()
	_dialog.file_mode = mode
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.title = title
	_dialog.use_native_dialog = true
	var arr := PackedStringArray()
	for f in filters:
		arr.append(String(f))
	_dialog.filters = arr
	if mode == FileDialog.FILE_MODE_SAVE_FILE and filters.size() > 0:
		_dialog.current_file = "图纸%s" % String(filters[0]).substr(1)
	_dialog.size = Vector2i(760, 520)
	add_child(_dialog)
	_dialog.file_selected.connect(func(p: String) -> void:
		if _dialog_cb.is_valid():
			_dialog_cb.call(p))
	_dialog_cb = cb
	_dialog.popup_centered()


func _do_open(path: String) -> void:
	var err := NativeFormat.load_into(doc, path)
	if err != OK:
		prompt_label.text = "打开失败（错误码 %d）：%s" % [err, path]
		return
	_current_path = path
	GbBlocks.install(doc)
	viewport.setup(doc)
	viewport.zoom_extents()
	_refresh_status()
	_show_status("已打开 %s（%d 个图元）" % [path.get_file(), doc.entity_count()])


func _do_save(path: String) -> void:
	_save_to(path)


func _save_to(path: String) -> void:
	var err := NativeFormat.save(doc, path)
	if err != OK:
		prompt_label.text = "保存失败（错误码 %d）：%s" % [err, path]
		return
	_current_path = path
	_show_status("已保存 %s（%d 个图元）" % [path.get_file(), doc.entity_count()])


func _do_export_dxf(path: String) -> void:
	var w := DxfWriter.new(doc)
	var err := w.save(path)
	if err != OK:
		prompt_label.text = "DXF 导出失败（错误码 %d）" % err
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var size := f.get_length() if f != null else 0
	if f != null:
		f.close()
	_show_status("已导出 DXF R12：%s（%.1f KB）%s" % [
		path.get_file(), size / 1024.0,
		"" if Gbk.is_available() else "  ⚠ GBK 表缺失，中文已写成 ?"])


func _do_export_svg(path: String) -> void:
	var w := SvgWriter.new(doc.plot_scale)
	var text := w.write(doc)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		prompt_label.text = "导出失败：无法写入 %s" % path
		return
	f.store_string(text)
	f.close()
	_show_status("已导出 SVG：%s" % path.get_file())


func _do_export_png(path: String) -> void:
	# 用视口的当前渲染结果出图（所见即所得），尺寸随窗口
	var img := viewport.get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	if err != OK:
		prompt_label.text = "导出失败（错误码 %d）" % err
		return
	_show_status("已导出 PNG：%s（%d×%d）" % [path.get_file(), img.get_width(), img.get_height()])


func _show_status(msg: String) -> void:
	if prompt_label != null:
		prompt_label.text = msg


## 由命令注册表生成分类下拉菜单
func _cmd_menu(label: String, categories: Array) -> MenuButton:
	var mb := MenuButton.new()
	mb.text = label
	mb.focus_mode = Control.FOCUS_NONE
	var pop := mb.get_popup()
	var by_cat := CommandRegistry.by_category()
	var first := true
	for cat in categories:
		if not by_cat.has(cat):
			continue
		if not first:
			pop.add_separator()
		first = false
		for item in by_cat[cat]:
			var cname := String(item[0])
			var chelp := String(item[1])
			pop.add_item("%s  %s" % [cname, _alias_suffix(cname)], -1)
			var idx := pop.item_count - 1
			pop.set_item_tooltip(idx, chelp)
			pop.set_item_metadata(idx, cname)
	pop.id_pressed.connect(func(id: int) -> void:
		# id 即条目索引，取回元数据里的规范命令名
		var n := pop.item_count
		for i in range(n):
			if pop.get_item_id(i) == id or i == id:
				var meta = pop.get_item_metadata(i)
				if meta != null:
					_run(String(meta))
				return
	)
	return mb


## 菜单里显示别名，便于用户记住简写
func _alias_suffix(cname: String) -> String:
	for d in CommandRegistry.DEFS:
		if String(d[0]) == cname:
			var al: Array = d[1]
			if al.size() > 0:
				return "(%s)" % String(al[0])
	return ""


func _build_command_line() -> Control:
	var panel := PanelContainer.new()
	var hb := HBoxContainer.new()
	panel.add_child(hb)
	var lbl := Label.new()
	lbl.text = "命令:"
	hb.add_child(lbl)
	cmd_edit = LineEdit.new()
	cmd_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cmd_edit.placeholder_text = "输入命令（LINE / L / 直线 / U 撤销），回车执行；空回车重复上一条命令"
	cmd_edit.text_submitted.connect(_on_command_submitted)
	hb.add_child(cmd_edit)
	return panel


func _build_status_bar() -> Control:
	var panel := PanelContainer.new()
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 16)
	panel.add_child(hb)

	coord_label = _status_label("X 0.00  Y 0.00")
	hb.add_child(coord_label)
	scale_label = _status_label("1:100")
	hb.add_child(scale_label)
	count_label = _status_label("图元 0")
	hb.add_child(count_label)
	sel_label = _status_label("选中 0")
	hb.add_child(sel_label)

	prompt_label = _status_label("")
	prompt_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(prompt_label)

	stat_label = _status_label("")
	hb.add_child(stat_label)
	return panel


func _status_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	return l


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


# ---------------------------------------------------------------------------
# 文档
# ---------------------------------------------------------------------------

func new_document() -> void:
	doc = CadDocument.new()
	# 每个文档都安装内置建筑图库，插入块时即可选用
	GbBlocks.install(doc)
	viewport.setup(doc)
	_refresh_status()


func load_demo() -> void:
	doc = CadDocument.new()
	GbBlocks.install(doc)
	doc.begin_transaction("载入示例图")
	DemoDrawing.build(doc)
	viewport.setup(doc)
	viewport.zoom_extents()
	_refresh_status()


# ---------------------------------------------------------------------------
# 交互回调
# ---------------------------------------------------------------------------

func _run(name: String) -> void:
	cmd_edit.text = ""
	viewport.run_command_by_name(name)
	_refresh_status()


func _do_undo() -> void:
	viewport.undo()
	_refresh_status()


func _do_redo() -> void:
	viewport.redo()
	_refresh_status()


func _on_command_submitted(text: String) -> void:
	var ok := viewport.submit_text(text)
	if not ok and text.strip_edges() != "":
		prompt_label.text = "未知命令: %s" % text.strip_edges()
	cmd_edit.text = ""
	_refresh_status()


func _on_cursor_moved(p: Vector2) -> void:
	coord_label.text = "X %s  Y %s" % [_fmt(p.x), _fmt(p.y)]


func _on_prompt_changed(text: String) -> void:
	if prompt_label != null:
		prompt_label.text = text


func _on_selection_changed(n: int) -> void:
	if sel_label != null:
		sel_label.text = "选中 %d" % n
	_refresh_status()


func _fmt(v: float) -> String:
	if absf(v) >= 1000.0:
		return "%.1f" % v
	return "%.2f" % v


func _refresh_status() -> void:
	if doc == null:
		return
	count_label.text = "图元 %d" % doc.entity_count()
	scale_label.text = viewport.view.approx_plot_scale()
	var s: Dictionary = viewport.renderer.stats
	if s.is_empty():
		stat_label.text = ""
	else:
		var flags := []
		if viewport.snap.osnap_enabled:
			flags.append("捕捉")
		if viewport.snap.ortho:
			flags.append("正交")
		if viewport.snap.grid_snap:
			flags.append("栅格")
		if viewport.snap.polar_enabled:
			flags.append("极轴")
		stat_label.text = "可见 %d/剔除 %d/线段 %d/批 %d  %s" % [
			int(s.get("drawn", 0)), int(s.get("culled", 0)),
			int(s.get("segments", 0)), int(s.get("buckets", 0)),
			("[" + "/".join(flags) + "]") if flags.size() > 0 else ""]


# ---------------------------------------------------------------------------
# 快捷键
# ---------------------------------------------------------------------------

func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var k := event as InputEventKey
	if k.ctrl_pressed or k.meta_pressed:
		match k.keycode:
			KEY_Z:
				_do_undo() if not k.shift_pressed else _do_redo()
				accept_event()
			KEY_Y:
				_do_redo()
				accept_event()
			KEY_S:
				viewport.zoom_extents()
				accept_event()
			KEY_N:
				new_document()
				accept_event()
			KEY_O:
				_on_file_menu(0)
				accept_event()
		return
	# 无修饰键：把焦点交给命令行，让用户直接敲命令
	if k.keycode == KEY_ESCAPE:
		cmd_edit.grab_focus()
		cmd_edit.select_all()
		accept_event()


var _help_window: Window = null


func _toggle_help() -> void:
	if _help_window != null and _help_window.visible:
		_help_window.hide()
		return
	if _help_window == null:
		_help_window = Window.new()
		_help_window.title = "操作说明"
		_help_window.size = Vector2i(560, 420)
		var te := RichTextLabel.new()
		te.bbcode_enabled = true
		te.set_anchors_preset(Control.PRESET_FULL_RECT)
		te.text = """[b]视图操作[/b]
  滚轮          以光标为中心缩放
  中键拖动      平移
  Ctrl+S        缩放到图纸范围

[b]绘图[/b]
  直线          LINE / L / 直线，或点工具栏"直线"
  空格 或 回车   结束当前命令；无命令时重复上一条命令
  Esc          取消当前命令

[b]编辑[/b]
  Ctrl+Z       撤销
  Ctrl+Y       重做
  Delete       删除选中对象
  Ctrl+A       全选
  左键拖拽     左到右 = 窗选（完全在内）
               右到左 = 交叉选（相交即选）
  Shift+拖拽   从选择集中移除
  拖动夹点     直接编辑图元几何

[b]捕捉与定位[/b]
  F3           对象捕捉（端点/中点/圆心/象限点/交点/垂足/切点）
  F8           正交
  F9           栅格捕捉
  F10          极轴追踪

[b]命令行的坐标输入[/b]
  100,200      绝对坐标
  @50,0        相对上一点
  @100<30      相对上一点，距离 100 角度 30°
"""
		_help_window.add_child(te)
		add_child(_help_window)
	_help_window.popup_centered()
