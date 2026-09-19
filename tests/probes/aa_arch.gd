extends Node
## 抗锯齿架构验证。
##
## 已知问题：主视口开启 msaa_2d 后，动态字体（FontFile/FontVariation）的所有字形
## 都会渲染为实心方块，中文与拉丁字母均失效。但矢量线段需要 MSAA 才不锯齿。
##
## 本实验验证目标架构：把矢量几何放进带 MSAA 的 SubViewport，文字与 UI 留在
## 无 MSAA 的主视口，两者叠加后是否同时正确。
##
## 同时对比 draw_multiline（快、可批量、无 AA）与 draw_polyline(antialiased=true)
## 的线条质量，为渲染器选型提供依据。

const SAMPLE := "长仿宋工程字 一层平面图 ABCDEFG 0123456789"
const FONT_PATH := "C:/Windows/Fonts/simfang.ttf"

var _font: FontFile
var _fang: FontVariation
var _osize := Vector2i(760, 420)


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DisplayServer.window_set_position(Vector2i(40, 40))
	get_viewport().msaa_2d = Viewport.MSAA_DISABLED

	_font = FontFile.new()
	_font.load_dynamic_font(FONT_PATH)
	_fang = FontVariation.new()
	_fang.base_font = _font
	_fang.variation_transform = Transform2D(Vector2(0.7, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)

	# 左：几何在带 MSAA 的 SubViewport 里（文字也放进去 —— 预期文字损坏）
	# 右：几何层带 MSAA，文字层单独无 MSAA
	_make_panel("左：SubViewport msaa=4x  （几何+文字混在一起）", Vector2i(10, 30), Viewport.MSAA_4X, false)
	_make_panel("右：SubViewport msaa=4x 仅几何 + 文字层无MSAA", Vector2i(800, 30), Viewport.MSAA_4X, true)
	_make_label("主视口 msaa=0 直接绘制（对照）", Vector2i(10, 470))

	var ref := Node2D.new()
	ref.draw.connect(_draw_sample.bind(ref, false))
	add_child(ref)

	for i in range(4):
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/out/_aa_arch.png")
	print("[shot] res://tests/out/_aa_arch.png")
	get_tree().quit(0)


func _make_label(text: String, pos: Vector2i) -> void:
	var l := Label.new()
	l.text = text
	l.position = Vector2(pos)
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	add_child(l)


## 造一个面板：SubViewport（可选 MSAA）渲染几何，文字层视 split_text 决定放哪。
func _make_panel(title: String, pos: Vector2i, msaa: int, split_text: bool) -> void:
	_make_label(title, pos - Vector2i(0, 24))

	# 几何层
	var geo_vp := SubViewport.new()
	geo_vp.size = _osize
	geo_vp.msaa_2d = msaa
	geo_vp.transparent_bg = false
	geo_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var geo := Node2D.new()
	geo.draw.connect(_draw_sample.bind(geo, false))
	geo_vp.add_child(geo)
	add_child(geo_vp)
	var geo_rect := TextureRect.new()
	geo_rect.texture = geo_vp.get_texture()
	geo_rect.position = Vector2(pos)
	geo_rect.size = Vector2(_osize)
	geo_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(geo_rect)

	if not split_text:
		# 文字与几何同处一个 MSAA 视口 —— 预期文字变方块
		var txt := Node2D.new()
		txt.draw.connect(_draw_text_only.bind(txt))
		geo_vp.add_child(txt)
		return

	# 文字层单独放在无 MSAA 的 SubViewport，叠在上面
	var txt_vp := SubViewport.new()
	txt_vp.size = _osize
	txt_vp.msaa_2d = Viewport.MSAA_DISABLED
	txt_vp.transparent_bg = true
	txt_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var txt := Node2D.new()
	txt.draw.connect(_draw_text_only.bind(txt))
	txt_vp.add_child(txt)
	add_child(txt_vp)
	var txt_rect := TextureRect.new()
	txt_rect.texture = txt_vp.get_texture()
	txt_rect.position = Vector2(pos)
	txt_rect.size = Vector2(_osize)
	txt_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(txt_rect)


func _draw_sample(c: Node2D, _unused: bool) -> void:
	var d := Vector2(_osize)
	c.draw_rect(Rect2(Vector2.ZERO, d), Color(0.09, 0.10, 0.12))
	_draw_vec_art(c)


## 一组用来评估抗锯齿质量的矢量图元：斜线、圆、圆弧、密集填充线
func _draw_vec_art(c: Node2D) -> void:
	var d := Vector2(_osize)
	# 斜线：最考验 AA
	for i in range(8):
		var t := float(i) / 7.0
		c.draw_line(Vector2(24.0 + t * 200.0, 40.0), Vector2(300.0, 150.0 + t * 60.0), Color(0.95, 0.95, 0.9), 1.0 + t, true)
	# 圆与圆弧
	c.draw_arc(Vector2(560.0, 110.0), 78.0, 0.0, TAU, 96, Color(1.0, 0.75, 0.3), 1.5, true)
	c.draw_arc(Vector2(560.0, 110.0), 52.0, 0.0, PI * 0.75, 64, Color(0.7, 0.9, 1.0), 1.0, true)
	# 国标 45° 素线填充（模拟砖砌体图例）
	var y := 240.0
	var x := 24.0
	while y < 400.0:
		c.draw_line(Vector2(x, y), Vector2(x + 60.0, y - 60.0), Color(0.6, 0.6, 0.65), 1.0, true)
		x += 12.0
		if x > 260.0:
			x = 24.0
			y += 12.0
	# 密集水平细线（最容易被混叠成灰带）
	for i in range(5):
		var yy := 250.0 + float(i) * 3.0
		c.draw_line(Vector2(320.0, yy), Vector2(720.0, yy), Color(0.9, 0.9, 0.9), 1.0, true)
	# 竖细线
	for i in range(40):
		var xx := 320.0 + float(i) * 10.0
		c.draw_line(Vector2(xx, 290.0), Vector2(xx, 400.0), Color(0.5, 0.8, 0.5), 1.0, true)


func _draw_text_only(c: Node2D) -> void:
	# 长仿宋正文与标注
	c.draw_string(_fang, Vector2(24, 56), SAMPLE, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color.WHITE)
	c.draw_string(_font, Vector2(24, 100), SAMPLE, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(1, 0.9, 0.6))
	c.draw_string(_fang, Vector2(24, 150), "±0.000  240厚烧结普通砖  M1  C1  ⌀10", HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(0.8, 1.0, 0.8))
