extends Node
## 截图验证工具。
##
## 关键：**必须先预热字体并等待足够帧数**。动态字体的字形图集是延迟光栅化的，
## 启动头几帧抓图会拍到白色占位纹理，看起来像"所有文字变成实心方块"。
## 详见 docs/引擎特性与坑.md 第 2 节。
##
## 运行：godot --path <项目> --quit-after 1200 res://tests/capture.tscn
## 输出：tests/out/_app.png（全图）、_detail.png（放大细节+线宽）、_snap.png（捕捉标记）

const WARMUP_FRAMES := 14


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DisplayServer.window_set_position(Vector2i(30, 30))

	var app := (load("res://src/main.tscn") as PackedScene).instantiate()
	add_child(app)
	FontManager.instance().warm_up()
	await _settle()

	var vp = app.get("viewport")
	await _shot("res://tests/out/_app.png", "全图")
	_report(vp)

	# 放大 + 线宽显示，核对国标线宽体系与虚线/点画线
	vp.renderer.show_lineweight = true
	vp.view.center = Vector2(3000.0, 2000.0)
	vp.view.zoom = 0.42
	vp.queue_redraw()
	await _settle()
	await _shot("res://tests/out/_detail.png", "放大细节 + 显示线宽")

	# 捕捉标记：把光标放到轴网交点附近，触发一次捕捉并绘制标记
	vp.renderer.show_lineweight = false
	vp.view.zoom = 0.35
	# 把视图中心对准想捕捉的特征点，再把光标放在靶框内的偏一点的位置。
	# 楼梯首级踏步的左端点 (3900, 180)，附近没有中点或交点竞争，
	# 能干净地验证"端点"捕捉与标记绘制。
	var target := Vector2(3900.0, 180.0)
	vp.view.center = target
	vp._mouse_inside = true
	# 直接按模型坐标指定光标：目标点偏移 (15,-10)，距端点 18mm，
	# 落在 12 像素靶框（zoom=0.35 时约 34mm）内。
	# 不要用屏幕像素偏移反推，缩放与 Y 翻转很容易算错。
	var want := target + Vector2(15.0, -10.0)
	vp.mouse_screen = vp.view.to_screen(want)
	vp.mouse_model = want
	vp.snapped_model(vp.mouse_screen)
	vp.queue_redraw()
	await _settle()
	await _shot("res://tests/out/_snap.png", "捕捉标记")
	print("[snap] 捕捉结果: 类型=%s 点=%s" % [
		SnapType.name_of(vp._last_snap.type) if vp._last_snap != null else "无",
		str(vp._last_snap.point) if vp._last_snap != null else "-"])
	get_tree().quit(0)


func _settle() -> void:
	for i in range(WARMUP_FRAMES):
		await RenderingServer.frame_post_draw


func _shot(path: String, label: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[capture] %s -> %s (err=%d)" % [label, path, err])


func _report(vp) -> void:
	if vp == null:
		return
	print("[stats] ", vp.renderer.stats)
	print("[stats] 图元=%d  图层数=%d  zoom=%.4f  比例=%s" % [
		vp.doc.entity_count(), vp.doc.layer_names().size(),
		vp.view.zoom, vp.view.approx_plot_scale()])
