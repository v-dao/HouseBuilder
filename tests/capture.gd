extends Node
## 截图验证工具。
##
## 关键：**必须先预热字体并等待足够帧数**。动态字体的字形图集是延迟光栅化的，
## 启动头几帧抓图会拍到白色占位纹理，看起来像"所有文字变成实心方块"。
## 详见 docs/引擎特性与坑.md 第 2 节。这里固定预热 + 等 14 帧。
##
## 运行：godot --path <项目> --quit-after 900 res://tests/capture.tscn
## 输出：tests/out/_app.png（全图）、tests/out/_detail.png（放大细节 + 显示线宽）

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
	await _shot("res://tests/out/_app.png", "全图（按真实线宽关，编辑常规状态）")
	_report(vp)

	# 第二张：放大到 1:20 左右并开启线宽显示，核对国标线宽体系与虚线/点画线
	vp.renderer.show_lineweight = true
	vp.view.center = Vector2(3000.0, 2000.0)
	vp.view.zoom = 0.42
	vp.queue_redraw()
	await _settle()
	await _shot("res://tests/out/_detail.png", "放大细节 + 显示线宽")
	_report(vp)
	get_tree().quit(0)


func _settle() -> void:
	for i in range(WARMUP_FRAMES):
		await RenderingServer.frame_post_draw


func _shot(path: String, label: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[capture] %s -> %s (err=%d, %dx%d)" % [label, path, err, img.get_width(), img.get_height()])


func _report(vp) -> void:
	if vp == null:
		return
	print("[stats] ", vp.renderer.stats)
	print("[stats] 图元=%d  图层=%s  zoom=%.4f  比例=%s  线宽显示=%s" % [
		vp.doc.entity_count(), str(vp.doc.layer_names()),
		vp.view.zoom, vp.view.approx_plot_scale(), str(vp.renderer.show_lineweight)])
