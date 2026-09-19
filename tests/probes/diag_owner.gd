extends Node
## 定位"客厅里那团随缩放不动的黄色"到底是谁画的。
##
## 用二分法：分别渲染
##   A 完整画面
##   B 只留视口自身的装饰（doc = null，网格 + 坐标轴还在）
##   C 只留图纸内容（关掉网格与坐标轴）
## 三者比对窗口矩形 (540,440)-(660,540) 内的黄色像素数，即可确定来源。

const WARMUP := 14
const Z := 0.0926
const CENTER := Vector2(1800.0, 1500.0)
const ROI := Rect2i(520, 420, 180, 140)


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DisplayServer.window_set_position(Vector2i(30, 30))

	var app := (load("res://src/main.tscn") as PackedScene).instantiate()
	add_child(app)
	FontManager.instance().warm_up()
	await _settle()

	var vp = app.get("viewport")
	var doc: CadDocument = vp.doc
	vp.view.center = CENTER
	vp.view.zoom = Z

	await _probe(vp, "A 完整画面", null, null, ROI)

	vp.doc = null
	vp.queue_redraw()
	await _settle()
	_probe_img("B 只留视口装饰(doc=null)", _grab(), ROI)
	vp.doc = doc
	vp.queue_redraw()

	vp.show_grid = false
	vp.show_axes = false
	vp.queue_redraw()
	await _settle()
	_probe_img("C 只留图纸内容(无网格/轴)", _grab(), ROI)
	vp.show_grid = true
	vp.show_axes = true
	vp.queue_redraw()

	# 逐图层单独显示，看这团黄属于哪个图层
	print("")
	print("---- 逐图层单独显示，ROI 内黄色像素数 ----")
	for name in doc.layers.keys():
		for k in doc.layers.keys():
			(doc.layers[k] as CadLayer).visible = (String(k) == String(name))
		vp.queue_redraw()
		await _settle()
		var n := _yellow_count(_grab(), ROI)
		if n > 0:
			print("  图层 %-10s -> 黄色像素 %d" % [name, n])
	for k in doc.layers.keys():
		(doc.layers[k] as CadLayer).visible = true
	vp.queue_redraw()
	get_tree().quit(0)


func _probe(vp, label: String, _a, _b, roi: Rect2i) -> void:
	vp.queue_redraw()
	await _settle()
	_probe_img(label, _grab(), roi)


func _probe_img(label: String, img: Image, roi: Rect2i) -> void:
	print("  %-28s ROI 内黄色像素 = %d" % [label, _yellow_count(img, roi)])


func _grab() -> Image:
	return get_viewport().get_texture().get_image()


func _yellow_count(img: Image, roi: Rect2i) -> int:
	var n := 0
	for y in range(roi.position.y, roi.end.y):
		for x in range(roi.position.x, roi.end.x):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			if c.r > 0.72 and c.g > 0.5 and c.b < 0.55:
				n += 1
	return n


func _settle() -> void:
	for i in range(WARMUP):
		await RenderingServer.frame_post_draw
