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
	var img1 := await _shot("res://tests/out/_app.png", "全图")

	# 关键回归检查：不改视图再抓一帧，这一帧走的是几何缓存**命中**路径。
	# 曾经文字只在缩放（缓存重建）时出现 —— 因为文字被错误地放进了
	# "缓存命中就跳过"的图元遍历里。连抓两帧做像素比对即可兜住它。
	var img2 := await _shot("res://tests/out/_app_cached.png", "全图（缓存命中）")
	var diff := _diff_ratio(img1, img2)
	print("[regression] 缓存命中帧与重建帧的像素差异 = %.4f%%  %s" % [
		diff * 100.0, "通过" if diff < 0.0005 else "**失败：两帧不一致，缓存边界有问题**"])
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

	# 对象捕捉追踪：起一条直线命令，获取两个基准点，
	# 把光标放到两条追踪轴的交点上，核对虚线是否画出来
	vp.exit_layout()
	vp.renderer.show_lineweight = false
	# 让两个基准点与它们的交点同时落在视野内
	vp.view.zoom = 0.09
	vp.view.center = Vector2(9000.0, 1200.0)
	vp.start_command(CmdLine.new())
	vp.snap.clear_tracking()
	# 选在建筑之外的空位取基准，避免与几何捕捉点冲突 ——
	# 几何捕捉优先于追踪（这是正确行为），所以要演示追踪本身就得避开前者
	vp.snap.acquire(Vector2(12000.0, 5000.0))  # 出竖直轴 x=12000 与水平轴 y=5000
	vp.snap.acquire(Vector2(6000.0, -3000.0))  # 出竖直轴 x=6000 与水平轴 y=-3000
	vp._mouse_inside = true
	var track_pos := Vector2(12012.0, -2988.0) # 靠近 x=12000 与 y=-3000 的交点
	vp.mouse_screen = vp.view.to_screen(track_pos)
	vp.mouse_model = track_pos
	vp._last_snap = vp.snap.resolve(vp.doc, vp.index, vp.view, track_pos,
		Vector2(1800.0, 1500.0))
	vp.queue_redraw()
	await _settle()
	await _shot("res://tests/out/_track.png", "对象捕捉追踪")
	print("[track] 基准点数=%d 捕捉类型=%s 捕捉点=%s 交点=%s" % [
		vp.snap.track_points.size(),
		SnapType.name_of(vp._last_snap.type) if vp._last_snap != null else "无",
		str(vp._last_snap.point) if vp._last_snap != null else "-",
		str(vp._last_snap.is_track_cross) if vp._last_snap != null else "-"])
	vp.cancel_command()

	# 图纸空间：核对图框、标题栏、视口内容是否按出图比例摆放
	var doc = vp.doc
	var layout: CadLayout = doc.ensure_layout()
	layout.title_fields = {
		"project": "某住宅小区 1# 楼", "drawing": "一层平面图",
		"number": "建施-05", "scale": "1:100",
		"design": "张", "draw": "李", "check": "王", "approve": "赵",
		"sign": "已会签",
	}
	vp._mouse_inside = false
	vp.enter_layout()
	await _settle()
	await _shot("res://tests/out/_layout.png", "图纸空间")
	print("[layout] 幅面=%s 视口比例=1:%d 纸张=%.0fx%.0fmm" % [
		layout.format, int(layout.main_viewport().scale),
		layout.paper_size().x, layout.paper_size().y])
	print("[layout] 视口覆盖模型区域 = %.0f x %.0f mm" % [
		layout.main_viewport().model_rect().size.x, layout.main_viewport().model_rect().size.y])
	get_tree().quit(0)


func _settle() -> void:
	for i in range(WARMUP_FRAMES):
		await RenderingServer.frame_post_draw


func _shot(path: String, label: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[capture] %s -> %s (err=%d)" % [label, path, err])
	return img


## 抽样比对两张图的像素差异比例
func _diff_ratio(a: Image, b: Image) -> float:
	if a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return 1.0
	var total := 0
	var n := 0
	for y in range(0, a.get_height(), 3):
		for x in range(0, a.get_width(), 3):
			total += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) > 0.02 or absf(ca.g - cb.g) > 0.02 or absf(ca.b - cb.b) > 0.02:
				n += 1
	return float(n) / float(maxi(total, 1))


func _report(vp) -> void:
	if vp == null:
		return
	print("[stats] ", vp.renderer.stats)
	print("[stats] 图元=%d  图层数=%d  zoom=%.4f  比例=%s" % [
		vp.doc.entity_count(), vp.doc.layer_names().size(),
		vp.view.zoom, vp.view.approx_plot_scale()])
