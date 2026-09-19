extends Node
## 截图链路验证：在没有实际绘图逻辑的情况下，确认可以把视口渲染结果存成 PNG。

var _frames := 0


func _ready() -> void:
	# --resolution 会被窗口的"最大化"模式覆盖，这里强制回窗口模式并固定尺寸，
	# 保证每次核对截图的分辨率与缩放一致。
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DisplayServer.window_set_position(Vector2i(40, 40))
	var canvas := Node2D.new()
	canvas.name = "TestCanvas"
	canvas.draw.connect(_on_draw)
	add_child(canvas)
	# 等渲染管线出图后再抓帧
	for i in range(3):
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "res://tests/out/_smoke.png"
	var err := img.save_png(path)
	print("[capture] 保存 ", path, " -> ", err, "  尺寸=", img.get_width(), "x", img.get_height())
	get_tree().quit(0)


func _on_draw() -> void:
	var c := get_viewport().get_visible_rect()
	var d := c.size
	var canvas := get_node("TestCanvas") as Node2D
	# 背景
	canvas.draw_rect(Rect2(Vector2.ZERO, d), Color(0.09, 0.10, 0.12))
	# 一组不同线宽的线，检查线宽渲染与抗锯齿
	for i in range(5):
		var y := 60.0 + float(i) * 40.0
		canvas.draw_line(Vector2(60, y), Vector2(d.x - 60.0, y), Color(0.95, 0.95, 0.9), 1.0 + float(i) * 1.5, true)
	# 中文文字（验证系统仿宋可加载 + 长仿宋 0.7 变换）
	var fv := FontVariation.new()
	var sys := SystemFont.new()
	sys.font_names = PackedStringArray(["FangSong", "仿宋", "SimSun", "宋体"])
	fv.base_font = sys
	fv.variation_transform = Transform2D(Vector2(0.7, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
	canvas.draw_string(fv, Vector2(60, 300), "长仿宋工程字 ABCDEFG 0123456789 一层平面图 1:100", HORIZONTAL_ALIGNMENT_LEFT, -1, 36, Color(1, 1, 1))
	canvas.draw_string(fv, Vector2(60, 360), "混凝土 钢筋混凝土 普通砖 夯实土壤 防水材料", HORIZONTAL_ALIGNMENT_LEFT, -1, 36, Color(0.6, 0.9, 1.0))
	# 一个圆，检查圆弧光顺度
	canvas.draw_arc(Vector2(d.x - 250.0, 300.0), 140.0, 0.0, TAU, 128, Color(1.0, 0.75, 0.3), 2.0, true)
