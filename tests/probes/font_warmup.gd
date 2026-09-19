extends Node
## 确认"豆腐块"是字体图集预热延迟，而非 MSAA 引起。
## 不再靠肉眼看图，改为程序化比对：在不同帧号抓帧，比较像素差异。
##   预期：第 3 帧与第 30 帧差异显著（早期为白色占位纹理）
##         第 30 帧与第 60 帧完全一致（已稳定）
## 若成立，则 MSAA 可放心使用，截图工具只需保证足够预热帧。

const FONT := "C:/Windows/Fonts/simfang.ttf"

var _cv: Node2D
var _frame := 0
var _shots: Array[Image] = []
var _shot_frames: Array[int] = []


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(900, 400))
	DisplayServer.window_set_position(Vector2i(40, 40))
	get_viewport().msaa_2d = Viewport.MSAA_4X

	_cv = Node2D.new()
	_cv.draw.connect(_on_draw)
	add_child(_cv)

	# 抓帧点：早期 vs 稳定后
	await _capture_at(3)
	await _capture_at(30)
	await _capture_at(60)

	print("=== 抓帧像素对比（视口 msaa_2d=", get_viewport().msaa_2d, "） ===")
	for i in range(_shots.size()):
		for j in range(i + 1, _shots.size()):
			var diff := _diff_ratio(_shots[i], _shots[j])
			print("  第%d帧 vs 第%d帧: 不同像素占比 = %.4f%%" % [_shot_frames[i], _shot_frames[j], diff * 100.0])
	print("判读：若(3,30)差异大而(30,60)为 0，则确认为预热延迟，MSAA 无关。")
	get_tree().quit(0)


func _process(_d: float) -> void:
	_frame += 1


func _capture_at(target: int) -> void:
	while _frame < target:
		await RenderingServer.frame_post_draw
	# 再多等一帧确保本帧渲染完成
	await RenderingServer.frame_post_draw
	_shots.append(get_viewport().get_texture().get_image())
	_shot_frames.append(_frame)


func _diff_ratio(a: Image, b: Image) -> float:
	if a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return 1.0
	var total := 0
	var n := 0
	# 抽样比较，避免逐像素过慢
	var step := 7
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			total += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) > 0.02 or absf(ca.g - cb.g) > 0.02 or absf(ca.b - cb.b) > 0.02:
				n += 1
	return float(n) / float(maxi(total, 1))


func _on_draw() -> void:
	var d := Vector2(900, 400)
	_cv.draw_rect(Rect2(Vector2.ZERO, d), Color(0.08, 0.09, 0.11))
	var ff := FontFile.new()
	ff.load_dynamic_font(FONT)
	var fv := FontVariation.new()
	fv.base_font = ff
	fv.variation_transform = Transform2D(Vector2(0.7, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
	_cv.draw_string(fv, Vector2(30, 70), "长仿宋工程字 一层平面图 ±0.000", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color.WHITE)
	_cv.draw_string(fv, Vector2(30, 130), "ABCDEFG 0123456789 240厚砖墙", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color(1, 0.9, 0.6))
	# 斜线对照：MSAA 是否生效
	_cv.draw_polyline(PackedVector2Array([Vector2(30, 200), Vector2(860, 260)]), Color(1, 0.6, 0.2), 1.0, false)
	_cv.draw_arc(Vector2(450, 320), 60.0, 0.0, TAU, 64, Color(0.6, 0.9, 1.0), 1.0, false)
	# 注意：画面内容必须只由文档决定，不含帧号等逐帧变化量，
	# 否则"稳定后两帧完全一致"这个判据会失效。
