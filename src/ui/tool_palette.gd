class_name ToolPalette
extends VBoxContainer
## 工具选项板：内置建筑图库的快速取用面板。
##
## 图库有二十多个块，每次都敲块名太慢。选项板按类别分组列出来，
## 点一下就进入插入命令并预填块名，剩下的只是点位置。
##
## 每个块给一句尺寸说明（取自 CadBlock.description），
## 免得用户点进去才发现尺寸不对。

signal block_chosen(name: String)

## 类别 -> 块名前缀。与 GbBlocks 的命名约定一致。
const CATEGORIES := [
	["门", ["M"]],
	["窗", ["C"]],
	["洁具", ["坐便器", "蹲便器", "洗手盆", "浴缸", "淋浴间"]],
	["厨房", ["灶台", "水槽", "冰箱"]],
	["家具", ["双人床", "单人床", "三人沙发", "餐桌", "衣柜", "电视柜"]],
	["楼梯", ["双跑楼梯"]],
]

var doc: CadDocument = null

var _tabs: TabContainer
var _hint: Label


func _ready() -> void:
	add_theme_constant_override("separation", 4)

	var title := Label.new()
	title.text = "图库"
	title.add_theme_font_size_override("font_size", 14)
	add_child(title)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.add_theme_color_override("font_color", Color(0.62, 0.70, 0.80))
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.text = "点图块后到图上点插入位置。全部按真实尺寸绘制，1:1 无需缩放。"
	add_child(_hint)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.custom_minimum_size = Vector2(0, 260)
	add_child(_tabs)


func setup(p_doc: CadDocument) -> void:
	doc = p_doc
	refresh()


func refresh() -> void:
	if _tabs == null:
		return
	for c in _tabs.get_children():
		c.queue_free()
	if doc == null:
		return
	for cat in CATEGORIES:
		var cat_name := String(cat[0])
		var keys: Array = cat[1]
		var names := _blocks_matching(keys)
		if names.is_empty():
			continue
		var page := _make_page(names)
		page.name = cat_name
		_tabs.add_child(page)


## 按前缀或精确名匹配图库中的块
func _blocks_matching(keys: Array) -> Array[String]:
	var out: Array[String] = []
	for n in GbBlocks.block_names():
		var name := String(n)
		if not doc.blocks.has(name):
			continue
		for k in keys:
			var key := String(k)
			# 单个字母视为前缀（M/C），多字视为精确名
			if key.length() == 1:
				if name.begins_with(key):
					out.append(name)
					break
			elif name == key:
				out.append(name)
				break
	out.sort()
	return out


func _make_page(names: Array[String]) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	for n in names:
		var blk := doc.get_block(n)
		var b := Button.new()
		b.text = n
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 12)
		if blk != null:
			b.tooltip_text = "%s\n%s\n含 %d 个图元" % [n, blk.description, blk.entities.size()]
		else:
			b.tooltip_text = n
		b.pressed.connect(func() -> void: block_chosen.emit(n))
		box.add_child(b)
		# 尺寸说明单独一行，弱化显示
		if blk != null and blk.description != "":
			var d := Label.new()
			d.text = "    " + blk.description
			d.add_theme_font_size_override("font_size", 10)
			d.add_theme_color_override("font_color", Color(0.55, 0.60, 0.68))
			box.add_child(d)
	return scroll
