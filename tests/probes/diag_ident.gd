extends Node
## 指认：初始视图（缩放全图）下每一处黄色像素簇，落在哪个图元上。
##
## 关键：全程用 vp.view.to_model() 换算，不手算屏幕与模型的关系 ——
## 前面正是手算错了才把 门窗表 里的黄色误当成"客厅里的黄线"。

const WARMUP := 14


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DisplayServer.window_set_position(Vector2i(30, 30))
	var app := (load("res://src/main.tscn") as PackedScene).instantiate()
	add_child(app)
	FontManager.instance().warm_up()
	await _settle()

	var vp = app.get("viewport")
	vp.zoom_extents()
	vp.queue_redraw()
	await _settle()
	print("初始视图：center=%s zoom=%.5f view_size=%s" % [
		str(vp.view.center), vp.view.zoom, str(vp.view.view_size)])
	var origin: Vector2 = (vp as CanvasItem).get_global_rect().position
	var img := get_viewport().get_texture().get_image()

	# 收集黄像素 -> 模型坐标 -> 聚簇
	var clusters: Array = []
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if not (c.r > 0.35 and c.r > c.b * 1.6 and c.g > c.r * 0.55):
				continue
			_pile(clusters, vp.view.to_model(Vector2(x, y) - origin))
	clusters.sort_custom(func(p, q): return int(p[1]) > int(q[1]))
	print("黄色簇数 = %d" % clusters.size())

	var doc := vp.doc as CadDocument
	for i in range(mini(clusters.size(), 8)):
		var cl: Array = clusters[i]
		var m: Vector2 = cl[0] / float(cl[1])
		print("")
		print("── 第%d簇 计数=%d  模型≈(%.0f, %.0f) ──" % [i + 1, int(cl[1]), m.x, m.y])
		for e in doc.entities:
			var bb := e.get_bbox()
			if not bb.grow(300.0).has_point(m):
				continue
			var d := 1.0e18
			for c in e.get_curves():
				var cp: Dictionary = c.closest_point(m)
				d = minf(d, float(cp["dist"]))
			print("   %-12s 层=%-8s aci=%-4d 颜色=%-26s 包围盒=(%.0f,%.0f)-(%.0f,%.0f) 距曲线=%.0f" % [
				e.type_name(), e.layer, e.aci, str(doc.resolve_color(e)),
				bb.position.x, bb.position.y, bb.end.x, bb.end.y, d])
	get_tree().quit(0)


func _pile(acc: Array, m: Vector2) -> void:
	for cl in acc:
		var ctr: Vector2 = cl[0] / float(cl[1])
		if ctr.distance_to(m) < 700.0:
			cl[0] = cl[0] + m
			cl[1] = int(cl[1]) + 1
			return
	acc.append([m, 1])


func _settle() -> void:
	for i in range(WARMUP):
		await RenderingServer.frame_post_draw
