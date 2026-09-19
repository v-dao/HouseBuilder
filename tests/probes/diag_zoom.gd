extends Node
## 诊断：找出"随缩放改变位置"的图元。
##
## 思路分两步，先定位图元再定位代码：
##   A. 枚举所有解析为"尺寸标注黄"的图元，打印模型包围盒 —— 先知道客厅附近
##      到底有哪些黄东西。
##   B. 在两个缩放级别下抓图，把高倍的黄色掩膜按视口中心降采样对齐到低倍，
##      两者对不上的地方就是"位置随缩放变化"的图元；再把差异像素反算回
##      模型坐标，指名道姓。
##
## 运行：godot --path <项目> --quit-after 4000 res://tests/diag_zoom.tscn

const WARMUP := 14
const Z1 := 0.0463
const Z2 := 0.0926


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
	_dump_yellow(doc)

	# 视图中心取客厅（示例图里 1800,1500 是客厅），缩放两倍
	vp.view.center = Vector2(1800.0, 1500.0)
	vp.view.zoom = Z1
	vp.queue_redraw()
	await _settle()
	var img1 := get_viewport().get_texture().get_image()
	img1.save_png("res://tests/out/_zoom_a.png")

	vp.view.zoom = Z2
	vp.queue_redraw()
	await _settle()
	var img2 := get_viewport().get_texture().get_image()
	img2.save_png("res://tests/out/_zoom_b.png")

	_compare(img1, img2, vp, doc)
	get_tree().quit(0)


## A. 枚举黄色图元
func _dump_yellow(doc: CadDocument) -> void:
	print("---- 黄色（尺寸标注层）图元清单 ----")
	var n := 0
	for e in doc.entities:
		if not e.visible:
			continue
		var c := doc.resolve_color(e)
		if not _is_yellow(c):
			continue
		var bb := e.get_bbox()
		n += 1
		var d := bb.get_center().distance_to(Vector2(1800.0, 1500.0))
		print("%-4d %-18s 层=%-8s 包围盒=(%.0f,%.0f)-(%.0f,%.0f)  距客厅=%.0f" % [
			n, e.type_name(), e.layer,
			bb.position.x, bb.position.y, bb.end.x, bb.end.y, d])
	print("共 %d 个黄色图元" % n)


## B. 两倍缩放下的黄色掩膜降采样后与低倍比对；把差异像素聚成簇，
##    再反算回模型坐标，直接指名"哪条线位置不对"。
func _compare(a: Image, b: Image, vp, doc: CadDocument) -> void:
	var c := Vector2(a.get_width(), a.get_height()) * 0.5
	var origin: Vector2 = (vp as CanvasItem).get_global_rect().position
	var clusters: Array = []      # [[模型坐标和, 计数, 屏幕包围盒]]
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			if not _is_yellow(a.get_pixel(x, y)):
				continue
			# 反算到高倍图的坐标（以视口中心为不动点放大 2 倍）
			var p := c + (Vector2(x, y) - c) * 2.0
			if _yellow_near(b, p, 3):
				continue
			_merge_cluster(clusters, Vector2(x, y), vp.view, origin)
	print("")
	print("---- 缩放一致性：低倍下的黄像素，在高倍图的对应位置找不到黄 ----")
	print("差异簇数 = %d" % clusters.size())
	clusters.sort_custom(func(p, q): return int(p[1]) > int(q[1]))
	for i in range(mini(clusters.size(), 12)):
		var cl: Array = clusters[i]
		var mp: Vector2 = cl[0] / float(cl[1])
		var bb: Rect2 = cl[2]
		print("  第%d簇 计数=%-5d 屏幕(%.0f,%.0f) 模型≈(%.0f, %.0f)" % [
			i + 1, int(cl[1]), bb.get_center().x, bb.get_center().y, mp.x, mp.y])
	# 把差异最大的那簇裁出来目视：低倍原样、高倍同位置
	if not clusters.is_empty():
		var top: Array = clusters[0]
		var sp: Vector2 = (top[2] as Rect2).get_center()
		print("")
		print("视图：中心=%s 缩放=%.5f 视口尺寸=%s 视口全局原点=%s" % [
			str(vp.view.center), vp.view.zoom, str(vp.view.view_size), str(origin)])
		print("差异簇屏幕=(%.0f,%.0f)  按视口原点换算模型=(%.0f, %.0f)  若原点为(0,0)则=(%.0f, %.0f)" % [
			sp.x, sp.y,
			vp.view.to_model(sp - origin).x, vp.view.to_model(sp - origin).y,
			vp.view.to_model(sp).x, vp.view.to_model(sp).y])
		var r := Rect2i(int(sp.x) - 160, int(sp.y) - 100, 320, 200)
		_crop(a, r).save_png("res://tests/out/_zoom_crop_a.png")
		_crop(b, r).save_png("res://tests/out/_zoom_crop_b.png")
		print("已裁剪差异区域 -> tests/out/_zoom_crop_a.png / _crop_b.png（同一窗口矩形）")
		_calibrate(doc, vp, a, origin)
		_bucket_probe(vp, Vector2(900.0, 600.0))
		_identify(doc, vp, sp - origin)


## 直接问渲染器：模型点附近的桶里是什么颜色、什么线宽。
## 桶里的点是渲染器自己的产出，不受我的坐标换算影响 —— 这是最终裁决。
func _bucket_probe(vp, at: Vector2) -> void:
	var r = vp.renderer
	print("")
	print("---- 渲染器桶检查：模型 (%.0f, %.0f) 半径 800mm 内的线段 ----" % [at.x, at.y])
	var found := 0
	for key in r._bucket_pts.keys():
		var pts: PackedVector2Array = r._bucket_pts[key]
		var meta: Array = r._bucket_meta[key]
		var near := 0
		var mn := Vector2(1e9, 1e9)
		var mx := Vector2(-1e9, -1e9)
		for i in range(0, pts.size(), 2):
			for p in [pts[i], pts[i + 1]]:
				if p.distance_to(at) < 800.0:
					near += 1
					mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
					mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
		if near > 0:
			found += 1
			print("  颜色=%-28s 线宽=%.2fpx 命中端点=%d 模型范围=(%.0f,%.0f)-(%.0f,%.0f)" % [
				str(meta[0]), float(meta[1]), near, mn.x, mn.y, mx.x, mx.y])
	print("  命中桶数 = %d（渲染器本轮共 %d 个桶）" % [found, r._bucket_pts.size()])


## 先校准坐标系：把几条已知的黄色线（门窗表的边框）的 to_screen 位置打印出来，
## 同时给出黄色掩膜的粗粒度 ASCII 图，两者对照即可确认换算没错。
func _calibrate(doc: CadDocument, vp, img: Image, origin: Vector2) -> void:
	print("")
	print("---- 校准：已知黄色线的屏幕位置 ----")
	for e in doc.entities:
		if e.type != CadEntity.Type.LINE or e.layer != "尺寸标注":
			continue
		var ln := e as EntLine
		if absf(ln.p0.x - ln.p1.x) > 1.0:
			continue
		print("  竖线 x=%.0f (y %.0f→%.0f) : 屏幕(%s → %s)" % [
			ln.p0.x, ln.p0.y, ln.p1.y,
			str(vp.view.to_screen(ln.p0) + origin), str(vp.view.to_screen(ln.p1) + origin)])
	print("---- 黄色掩膜 ASCII 图（窗口 1600x900，每格 20x20 像素）----")
	var gw := 80
	var gh := 45
	for gy in range(gh):
		var line := ""
		for gx in range(gw):
			var hit := false
			for dy in range(0, 20, 4):
				for dx in range(0, 20, 4):
					var x := gx * 20 + dx
					var y := gy * 20 + dy
					if x < img.get_width() and y < img.get_height() and _is_yellow(img.get_pixel(x, y)):
						hit = true
			line += "#" if hit else "."
		print("  %s" % line)


## 差异像素反算出的模型点，附近到底有谁？按"真实几何距离"筛，不看包围盒。
func _identify(doc: CadDocument, vp, local_p: Vector2) -> void:
	var m: Vector2 = vp.view.to_model(local_p)
	print("")
	print("---- 该点模型坐标 (%.0f, %.0f) 附近的图元 ----" % [m.x, m.y])
	for e in doc.entities:
		var bb := e.get_bbox()
		if not bb.grow(50.0).has_point(m):
			continue
		var d := 1.0e18
		for c in e.get_curves():
			var cp: Dictionary = c.closest_point(m)
			d = minf(d, float(cp["dist"]))
		var on_seg := d
		if e.type == CadEntity.Type.INSERT or e.type == CadEntity.Type.WALL:
			# 块引用/墙体的曲线要按插入变换/墙体轮廓展开后才算准
			on_seg = -1.0
		print("  %-10s 层=%-8s aci=%-4d 颜色=%s 包围盒=(%.0f,%.0f)-(%.0f,%.0f) 点到曲线=%.1f" % [
			e.type_name(), e.layer, e.aci, str(doc.resolve_color(e)),
			bb.position.x, bb.position.y, bb.end.x, bb.end.y, on_seg])


func _crop(img: Image, r: Rect2i) -> Image:
	var out := Image.create(r.size.x, r.size.y, false, img.get_format())
	for y in range(r.size.y):
		for x in range(r.size.x):
			var sx := clampi(r.position.x + x, 0, img.get_width() - 1)
			var sy := clampi(r.position.y + y, 0, img.get_height() - 1)
			out.set_pixel(x, y, img.get_pixel(sx, sy))
	return out


## 把屏幕差异点的模型坐标累加，按 600mm 半径聚簇
func _merge_cluster(clusters: Array, screen_p: Vector2, view, origin: Vector2) -> void:
	var m: Vector2 = view.to_model(screen_p - origin)
	for cl in clusters:
		var ctr: Vector2 = cl[0] / float(cl[1])
		if ctr.distance_to(m) < 600.0:
			cl[0] = cl[0] + m
			cl[1] = int(cl[1]) + 1
			cl[2] = (cl[2] as Rect2).merge(Rect2(screen_p, Vector2.ONE))
			return
	clusters.append([m, 1, Rect2(screen_p, Vector2.ONE)])


func _is_yellow(c: Color) -> bool:
	return c.r > 0.72 and c.g > 0.5 and c.b < 0.55


func _yellow_near(img: Image, p: Vector2, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var x := int(p.x) + dx
			var y := int(p.y) + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if _is_yellow(img.get_pixel(x, y)):
				return true
	return false


func _settle() -> void:
	for i in range(WARMUP):
		await RenderingServer.frame_post_draw
