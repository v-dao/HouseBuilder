extends Node
## 最后一次架构实验：MSAA 2D 破坏字体渲染，是否可以通过字体自身设置规避？
## 若某个设置组合能在 msaa_2d>0 下正确出字，就能省掉整层 SubViewport 合成，
## 让几何走批量绘制 + MSAA，文字同视口直绘 —— 这是最理想的架构。
##
## 测试矩阵（全部在 msaa_2d=4x 的视口内绘制）：
##   1 默认
##   2 subpixel_positioning = DISABLED
##   3 antialiasing = NONE
##   4 multichannel_signed_distance_field = true
##   5 generate_mipmaps = false
##   6 Control 节点 Label（走另一条渲染路径）
## 每行右侧配一条斜线作为 MSAA 生效的对照。

const FONT := "C:/Windows/Fonts/simfang.ttf"
const TXT := "长仿宋 ABC 123 ±0.000"

var _variants: Array[Font] = []
var _labels: Array[String] = []
var _cv: Node2D


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1400, 860))
	DisplayServer.window_set_position(Vector2i(40, 40))
	get_viewport().msaa_2d = Viewport.MSAA_4X
	print("主视口 msaa_2d = ", get_viewport().msaa_2d)

	_add("1 默认", _mk())
	_add("2 子像素定位关", _mk(func(f: FontFile): f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED))
	_add("3 抗锯齿关", _mk(func(f: FontFile): f.antialiasing = TextServer.FONT_ANTIALIASING_NONE))
	_add("4 MSDF", _mk(func(f: FontFile): f.multichannel_signed_distance_field = true))
	_add("5 无mipmap", _mk(func(f: FontFile): f.generate_mipmaps = false))
	_add("6 关闭系统回退", _mk(func(f: FontFile): f.allow_system_fallback = false))

	_cv = Node2D.new()
	_cv.draw.connect(_on_draw)
	add_child(_cv)

	# 7 号：Control 路径的 Label
	var l := Label.new()
	l.position = Vector2(760, 60)
	l.text = "7 Label(Control): " + TXT
	l.add_theme_font_override("font", _variants[0])
	l.add_theme_font_size_override("font_size", 30)
	add_child(l)

	for i in range(4):
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/out/_msaa_font_matrix.png")
	print("[shot] res://tests/out/_msaa_font_matrix.png")
	get_tree().quit(0)


func _add(label: String, f: Font) -> void:
	_labels.append(label)
	_variants.append(f)


func _mk(tweak: Callable = Callable()) -> Font:
	var ff := FontFile.new()
	ff.load_dynamic_font(FONT)
	if tweak.is_valid():
		tweak.call(ff)
	var fv := FontVariation.new()
	fv.base_font = ff
	fv.variation_transform = Transform2D(Vector2(0.7, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
	return fv


func _on_draw() -> void:
	var cv := _cv
	cv.draw_rect(Rect2(Vector2.ZERO, Vector2(1400, 860)), Color(0.08, 0.09, 0.11))
	var f := ThemeDB.fallback_font
	var y := 50.0
	for i in range(_variants.size()):
		cv.draw_string(f, Vector2(24, y), _labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0.55, 0.75, 0.95))
		cv.draw_string(_variants[i], Vector2(210, y), TXT, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color.WHITE)
		# 对照斜线：若它为平滑状，说明 MSAA 生效
		cv.draw_polyline(PackedVector2Array([Vector2(560, y), Vector2(740, y - 26.0)]), Color(1.0, 0.6, 0.2), 1.0, false)
		y += 60.0
	cv.draw_string(f, Vector2(24, y + 20.0), "对照：上方每条斜线若呈平滑抗锯齿，则 MSAA 已生效", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0.55, 0.75, 0.95))
