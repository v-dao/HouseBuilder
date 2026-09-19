extends Node
## 直接倾倒渲染器的分桶内容：桶里到底是模型坐标还是屏幕坐标？
## 这是判定"某条线随缩放乱跑"的决定性证据 —— 桶是渲染器自己的产出，
## 不经过我的任何坐标换算。

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
	vp.view.center = Vector2(1800.0, 1500.0)
	vp.view.zoom = 0.0926
	vp.queue_redraw()
	await _settle()

	var r = vp.renderer
	print("视图：center=%s zoom=%.4f view_size=%s" % [
		str(vp.view.center), vp.view.zoom, str(vp.view.view_size)])
	print("桶数 = %d" % r._bucket_pts.size())
	for key in r._bucket_pts.keys():
		var pts: PackedVector2Array = r._bucket_pts[key]
		var meta: Array = r._bucket_meta[key]
		var mn := Vector2(1e9, 1e9)
		var mx := Vector2(-1e9, -1e9)
		for p in pts:
			mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
			mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
		# 模型空间下 y 会到几千；屏幕空间下 y 只在 0~900、x 只在 0~1600
		var looks_screen := mx.x < 1700.0 and mx.y < 950.0 and mn.x > -400.0
		print("  颜色=%-26s 宽=%.2f 点数=%-7d 范围=(%.0f,%.0f)-(%.0f,%.0f) %s" % [
			str(meta[0]), float(meta[1]), pts.size(), mn.x, mn.y, mx.x, mx.y,
			"<-- 疑似屏幕坐标" if looks_screen else ""])
	get_tree().quit(0)


func _settle() -> void:
	for i in range(WARMUP):
		await RenderingServer.frame_post_draw
