extends Node
## 字体加载路径诊断：找出在 Godot 4.7 下可靠加载中文仿宋的方式。
## 这是整个软件中文显示的基础，必须先确定哪条路走得通。

const TEST_STR := "长仿宋工程字"


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DisplayServer.window_set_position(Vector2i(40, 40))

	print("=== OS.get_system_fonts() 里的候选 ===")
	var all := OS.get_system_fonts()
	print("系统字体总数: ", all.size())
	for nm in all:
		var low := String(nm).to_lower()
		if low.contains("fang") or low.contains("song") or low.contains("sun") or low.contains("kai") or low.contains("hei") or low.contains("yahei") or low.contains("noto"):
			print("  候选: ", nm)

	print("\n=== OS.get_system_font_path 逐个尝试 ===")
	for nm in ["FangSong", "仿宋", "SimSun", "宋体", "SimHei", "黑体", "KaiTi", "Microsoft YaHei", "Noto Sans SC"]:
		var p := OS.get_system_font_path(nm, 400, 100, false)
		print("  ", nm, " -> ", p if p != "" else "(未找到)")

	print("\n=== FontFile.load_dynamic_font 直接读文件 ===")
	for path in [
		"C:/Windows/Fonts/simfang.ttf",
		"C:/Windows/Fonts/simhei.ttf",
		"C:/Windows/Fonts/simkai.ttf",
		"C:/Windows/Fonts/simsun.ttc",
		"C:/Windows/Fonts/NotoSansSC-VF.ttf",
	]:
		_test_fontfile(path)

	print("\n=== SystemFont 方式 ===")
	var sys := SystemFont.new()
	sys.font_names = PackedStringArray(["仿宋", "FangSong"])
	_test_font(sys, "SystemFont([仿宋, FangSong])")
	var sys2 := SystemFont.new()
	sys2.font_names = PackedStringArray(["Microsoft YaHei"])
	_test_font(sys2, "SystemFont([Microsoft YaHei])")

	# 出图：直接路径加载的字体 + 长仿宋 0.7 变换
	var canvas := Node2D.new()
	canvas.draw.connect(_draw_with_font.bind(canvas))
	add_child(canvas)
	for i in range(3):
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://tests/out/_font_probe.png")
	print("\n[capture] 已保存 res://tests/out/_font_probe.png")
	get_tree().quit(0)


func _test_fontfile(path: String) -> void:
	if not FileAccess.file_exists(path):
		print("  ", path, " -> 文件不存在")
		return
	var ff := FontFile.new()
	var err := ff.load_dynamic_font(path)
	if err != OK:
		print("  ", path, " -> load_dynamic_font 失败 err=", err)
		return
	_test_font(ff, "FontFile(" + path.get_file() + ")")


func _test_font(f: Font, label: String) -> void:
	var gid := f.get_char_size("长".unicode_at(0), 32)
	var size := f.get_string_size(TEST_STR, HORIZONTAL_ALIGNMENT_LEFT, -1, 32)
	var has := f.has_char("长".unicode_at(0))
	print("  ", label, " | has_char('长')=", has, " | 字形尺寸=", gid, " | 串尺寸=", size)


func _draw_with_font(canvas: Node2D) -> void:
	var d := canvas.get_viewport_rect().size
	canvas.draw_rect(Rect2(Vector2.ZERO, d), Color(0.09, 0.10, 0.12))
	var y := 60.0

	var ff := FontFile.new()
	ff.load_dynamic_font("C:/Windows/Fonts/simfang.ttf")

	# 1) 裸字体
	canvas.draw_string(ff, Vector2(40, y), "① 裸仿宋: " + TEST_STR + " ABC 123", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color.WHITE)
	y += 70.0

	# 2) 长仿宋：0.7 横向压缩
	var fv := FontVariation.new()
	fv.base_font = ff
	fv.variation_transform = Transform2D(Vector2(0.7, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
	canvas.draw_string(fv, Vector2(40, y), "② 长仿宋0.7: " + TEST_STR + " ABC 123", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color(1, 0.9, 0.6))
	y += 70.0

	# 3) 75° 斜体（字母数字）
	var fvi := FontVariation.new()
	fvi.base_font = ff
	fvi.variation_transform = Transform2D(Vector2(1.0, 0.0), Vector2(0.2679492, 1.0), Vector2.ZERO)
	canvas.draw_string(fvi, Vector2(40, y), "③ 75°斜体: ABCDEFGHIJ 0123456789", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color(0.7, 0.9, 1.0))
	y += 70.0

	# 4) 黑体 / 楷体
	var fh := FontFile.new()
	fh.load_dynamic_font("C:/Windows/Fonts/simhei.ttf")
	canvas.draw_string(fh, Vector2(40, y), "④ 黑体: " + TEST_STR + " 标题常用", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color(0.8, 1.0, 0.8))
	y += 70.0
	var fk := FontFile.new()
	fk.load_dynamic_font("C:/Windows/Fonts/simkai.ttf")
	canvas.draw_string(fk, Vector2(40, y), "⑤ 楷体: " + TEST_STR + " 说明常用", HORIZONTAL_ALIGNMENT_LEFT, -1, 40, Color(1, 0.8, 0.9))
	y += 70.0

	# 5) 国标字高序列实测（字高 2.5/3.5/5/7/10/14/20 mm 的等比可视化）
	canvas.draw_string(ff, Vector2(40, y + 10.0), "⑥ 国标字高序列 3.5/5/7/10/14/20 :", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color(0.9, 0.9, 0.9))
	var x := 40.0
	for h in [3.5, 5.0, 7.0, 10.0, 14.0, 20.0]:
		var fv2 := FontVariation.new()
		fv2.base_font = ff
		fv2.variation_transform = Transform2D(Vector2(0.7, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
		var px := float(h) * 3.2
		canvas.draw_string(fv2, Vector2(x, y + 90.0), "字%d" % int(h), HORIZONTAL_ALIGNMENT_LEFT, -1, int(px), Color(1.0, 0.95, 0.7))
		x += px * 2.6
