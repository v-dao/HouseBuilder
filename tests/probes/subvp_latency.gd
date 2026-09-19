extends Node
## 渲染架构的最后一个未决问题：
## SubViewport 合成是否有 1 帧延迟？若有，平移缩放时文字会相对几何抖动，方案不可用。
##
## 做法：SubViewport 里画一个随帧号移动的方块，主视口里用同一帧号直接画一个方块。
## 抓帧比对两者位置。若一致 -> 同帧合成，方案可用。
## 同时对 msaa_2d=0 下 draw_polyline(antialiased=true) 的线条质量做评估（方案 B 备选）。

const VP_SIZE := Vector2i(400, 260)

var _frame := 0
var _geo_node: Node2D
var _ref_node: Node2D
var _sub: SubViewport
var _report: Array[String] = []


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DisplayServer.window_set_position(Vector2i(40, 40))
	get_viewport().msaa_2d = Viewport.MSAA_DISABLED

	_make_title("A 合成延迟测试：上=SubViewport输出，下=主视口直绘（同一帧号）", Vector2i(10, 8))

	# SubViewport 内容随帧号移动
	_sub = SubViewport.new()
	_sub.size = VP_SIZE
	_sub.msaa_2d = Viewport.MSAA_4X
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_geo_node = Node2D.new()
	_geo_node.draw.connect(_draw_moving.bind(_geo_node, true))
	_sub.add_child(_geo_node)
	add_child(_sub)
	var tr := TextureRect.new()
	tr.texture = _sub.get_texture()
	tr.position = Vector2(10, 30)
	tr.size = Vector2(VP_SIZE)
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(tr)

	# 主视口直绘同样的内容（无 MSAA）
	_ref_node = Node2D.new()
	_ref_node.draw.connect(_draw_moving.bind(_ref_node, false))
	_ref_node.position = Vector2(10, 30 + VP_SIZE.y + 10)
	add_child(_ref_node)

	_make_title("B msaa_2d=0 下 draw_polyline(antialiased=true) 的质量", Vector2i(440, 8))
	var qa := Node2D.new()
	qa.draw.connect(_draw_quality.bind(qa))
	qa.position = Vector2(440, 30)
	add_child(qa)

	_make_title("C msaa_2d=0 下 draw_multiline 的质量（无AA）", Vector2i(440, 320))
	var qb := Node2D.new()
	qb.draw.connect(_draw_quality_noaa.bind(qb))
	qb.position = Vector2(440, 342)
	add_child(qb)

	# 逐帧推进，记录位置
	for i in range(4):
		await RenderingServer.frame_post_draw
		if i >= 1:
			_report.append("帧%d: 帧号=%d 期望方块y=%.0f" % [i, _frame, _block_y()])
	get_viewport().get_texture().get_image().save_png("res://tests/out/_latency.png")
	for line in _report:
		print(line)
	print("[shot] res://tests/out/_latency.png")
	get_tree().quit(0)


func _make_title(text: String, pos: Vector2i) -> void:
	var l := Label.new()
	l.text = text
	l.position = Vector2(pos)
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	add_child(l)


## 方块位置：每帧右移并上下摆动，位置完全由当前帧号决定
func _block_y() -> float:
	return 40.0 + float((_frame * 13) % 120)


## 帧号在 _process 里统一自增，保证同帧内 SubViewport 与主视口读到同一个值。
## （若在 _draw 回调里自增，两个节点绘制顺序会造成假的"错位一帧"。）
func _process(_delta: float) -> void:
	_frame += 1


func _draw_moving(c: Node2D, _is_sub: bool) -> void:
	var y := _block_y()
	c.draw_rect(Rect2(Vector2.ZERO, Vector2(VP_SIZE)), Color(0.08, 0.09, 0.11))
	# 参照栅格：每 20px 一条水平线，便于读数
	for i in range(0, 14):
		var yy := float(i) * 20.0
		c.draw_line(Vector2(0, yy), Vector2(float(VP_SIZE.x), yy), Color(0.22, 0.24, 0.28), 1.0)
	# 移动方块
	var x := 40.0 + float((_frame * 7) % 300)
	c.draw_rect(Rect2(Vector2(x, y), Vector2(46, 26)), Color(1.0, 0.55, 0.15))
	c.draw_rect(Rect2(Vector2(x, y), Vector2(46, 26)), Color(1.0, 1.0, 1.0), false, 1.0)
	# 标注帧号与坐标
	var f := ThemeDB.fallback_font
	c.draw_string(f, Vector2(6, 18), "帧号 %d  x=%.0f y=%.0f" % [_frame, x, y], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.8, 1.0, 0.8))


func _draw_quality(c: Node2D) -> void:
	c.draw_rect(Rect2(Vector2.ZERO, Vector2(400, 270)), Color(0.08, 0.09, 0.11))
	# 圆（AA polyline）
	var pts := PackedVector2Array()
	for i in range(97):
		var a := TAU * float(i) / 96.0
		pts.append(Vector2(200.0 + 100.0 * cos(a), 90.0 + 60.0 * sin(a)))
	c.draw_polyline(pts, Color(1.0, 0.75, 0.3), 1.5, true)
	# 斜线组（AA polyline，每段一条）
	for i in range(10):
		c.draw_polyline(PackedVector2Array([Vector2(10.0, 180.0 + float(i) * 4.0), Vector2(190.0, 210.0 + float(i) * 4.0)]), Color(0.95, 0.95, 0.9), 1.0, true)
	# 国标 45° 填充
	var x := 220.0
	while x < 390.0:
		c.draw_polyline(PackedVector2Array([Vector2(x, 250.0), Vector2(x + 60.0, 190.0)]), Color(0.6, 0.6, 0.65), 1.0, true)
		x += 12.0


func _draw_quality_noaa(c: Node2D) -> void:
	c.draw_rect(Rect2(Vector2.ZERO, Vector2(400, 270)), Color(0.08, 0.09, 0.11))
	var pts := PackedVector2Array()
	for i in range(97):
		var a := TAU * float(i) / 96.0
		pts.append(Vector2(200.0 + 100.0 * cos(a), 90.0 + 60.0 * sin(a)))
	var flat := PackedVector2Array()
	for i in range(pts.size() - 1):
		flat.append(pts[i])
		flat.append(pts[i + 1])
	c.draw_multiline(flat, Color(1.0, 0.75, 0.3), 1.5)
	for i in range(10):
		c.draw_line(Vector2(10.0, 180.0 + float(i) * 4.0), Vector2(190.0, 210.0 + float(i) * 4.0), Color(0.95, 0.95, 0.9), 1.0, false)
	var flat2 := PackedVector2Array()
	var x := 220.0
	while x < 390.0:
		flat2.append(Vector2(x, 250.0))
		flat2.append(Vector2(x + 60.0, 190.0))
		x += 12.0
	c.draw_multiline(flat2, Color(0.6, 0.6, 0.65), 1.0)
