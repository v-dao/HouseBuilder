extends Node
## 隔离实验：判定"字形渲染成实心方块"的根因。
## 变量：字体来源（内置默认 / 动态加载仿宋）、MSAA 2D 开关。
## 另外直接把字体图集纹理导出成 PNG，看光栅化结果本身是否正确。

var _canvas: Node2D
var _font_a: Font   # 内置默认字体
var _font_b: Font   # 动态加载仿宋
var _use_msaa := true


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DisplayServer.window_set_position(Vector2i(40, 40))

	_font_a = ThemeDB.fallback_font
	var ff := FontFile.new()
	var err := ff.load_dynamic_font("C:/Windows/Fonts/simfang.ttf")
	print("load_dynamic_font err = ", err)
	_font_b = ff

	# 直接导出字体图集，绕开视口渲染这条路径
	_dump_atlas(ff)

	_canvas = Node2D.new()
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)

	await _shoot("res://tests/out/_probe_msaa4.png")

	_use_msaa = false
	get_viewport().msaa_2d = Viewport.MSAA_DISABLED
	print("msaa_2d 已切换为 ", get_viewport().msaa_2d)
	await _shoot("res://tests/out/_probe_msaa0.png")

	get_tree().quit(0)


func _shoot(path: String) -> void:
	for i in range(4):
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[shot] ", path)


func _dump_atlas(ff: FontFile) -> void:
	# 先渲染一次字符串，促使 TextServer 生成字形图集
	ff.get_string_size("长仿宋工程字ABCDEFG0123456789", HORIZONTAL_ALIGNMENT_LEFT, -1, 40)
	var n_cache := ff.get_cache_count()
	print("cache_count = ", n_cache)
	var probe_size := 40
	for ci in range(n_cache):
		print("  cache[", ci, "] ascent=", ff.get_cache_ascent(ci, probe_size))
		var n_tex := ff.get_texture_count(ci, Vector2i(probe_size, 0))
		print("  cache[", ci, "] texture_count=", n_tex)
		for ti in range(n_tex):
			var img := ff.get_texture_image(ci, Vector2i(probe_size, 0), ti)
			if img == null:
				print("    texture[", ti, "] = null")
				continue
			print("    texture[", ti, "] 尺寸=", img.get_width(), "x", img.get_height(), " 格式=", img.get_format())
			if img.get_width() > 0 and img.get_height() > 0:
				img.save_png("res://tests/out/_atlas_%d_%d.png" % [ci, ti])


func _on_draw() -> void:
	var d := _canvas.get_viewport_rect().size
	_canvas.draw_rect(Rect2(Vector2.ZERO, d), Color(0.09, 0.10, 0.12))
	var y := 70.0
	_canvas.draw_string(_font_a, Vector2(40, y), "A 内置默认字体: ABCDEFG 0123456789 长仿宋工程字", HORIZONTAL_ALIGNMENT_LEFT, -1, 44, Color.WHITE)
	y += 90.0
	_canvas.draw_string(_font_b, Vector2(40, y), "B 动态仿宋: ABCDEFG 0123456789 长仿宋工程字", HORIZONTAL_ALIGNMENT_LEFT, -1, 44, Color(1, 0.9, 0.6))
	y += 90.0
	var fv := FontVariation.new()
	fv.base_font = _font_b
	fv.variation_transform = Transform2D(Vector2(0.7, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
	_canvas.draw_string(fv, Vector2(40, y), "C 长仿宋0.7: ABCDEFG 0123456789 长仿宋工程字", HORIZONTAL_ALIGNMENT_LEFT, -1, 44, Color(0.7, 0.9, 1.0))
	y += 120.0
	_canvas.draw_string(_font_b, Vector2(40, y), "D 大号字号 96px: 建筑", HORIZONTAL_ALIGNMENT_LEFT, -1, 96, Color(0.8, 1.0, 0.8))
	# 参照物：矢量线，确认视口渲染本身正常
	_canvas.draw_line(Vector2(40, y + 40.0), Vector2(d.x - 40.0, y + 40.0), Color(1, 0.4, 0.4), 2.0, true)
