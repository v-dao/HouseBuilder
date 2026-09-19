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

	# 关键回归：尺寸线必须画在它自己的位置上。
	# 用户报告过"客厅处的黄线会跟随缩放改变位置" —— 根因是连续线型的图元
	# 在入桶前被变换了一次、提交时又被变换一次。分桶不变性有单元测试兜着，
	# 这里再从像素侧兜一道：真画出来的东西必须落在该图元的模型位置上。
	await _check_lines_painted_on_target(vp)
	await _check_no_stray_yellow(vp)

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


## 尺寸线必须画在自己的位置上。
##
## 判据与缩放无关：沿尺寸线的模型路径均匀取点，映射到屏幕后，
## 该处必须能找到本层的线像素。图元被变换两次时，它会整体跑到别的
## 模型位置上去，自己该在的地方反而是空的，这里立刻暴露。
##
## 不比对两张缩放的图 —— 二次变换的误差是自洽的（低倍图上那个错误位置
## 换算成模型坐标，正好就是高倍图上要画的位置），两图比对反而看不出来。
func _check_lines_painted_on_target(vp) -> void:
	vp.exit_layout()
	vp.view.center = Vector2(1800.0, 1500.0)
	vp.view.zoom = 0.0463
	vp.queue_redraw()
	await _settle()
	var img := await _shot("res://tests/out/_lines.png", "尺寸线落位")
	var origin: Vector2 = (vp as CanvasItem).get_global_rect().position

	var total := 0
	var hit := 0
	var bad: Array[String] = []
	for e in (vp.doc as CadDocument).entities:
		if not (e is EntLine) or e.layer != "尺寸标注" or not e.visible:
			continue
		var ln := e as EntLine
		if not _is_yellow_px(vp.doc.resolve_color(ln)):
			continue
		var n := 12
		var h := 0
		for i in range(n):
			var t := (float(i) + 0.5) / float(n)
			var m: Vector2 = ln.p0.lerp(ln.p1, t)
			if not vp.view.visible_rect().has_point(m):
				continue
			total += 1
			if _yellow_near_px(img, vp.view.to_screen(m) + origin, 3):
				hit += 1
			else:
				h += 1
		if h > 0:
			bad.append("直线(%.0f,%.0f)-(%.0f,%.0f) 落空 %d 处" % [
				ln.p0.x, ln.p0.y, ln.p1.x, ln.p1.y, h])
	var ratio := 0.0 if total == 0 else float(hit) / float(total)
	print("[regression] 尺寸线落位：采样 %d 点，命中 %d 点（%.0f%%） %s" % [
		total, hit, ratio * 100.0,
		"通过" if (total > 0 and ratio >= 0.9) else "**失败：尺寸线没有画在自己的位置上**"])
	for b in bad:
		print("    %s" % b)


## 该像素是否属于"尺寸标注"层的黄
func _is_yellow_px(c: Color) -> bool:
	return c.r > 0.72 and c.g > 0.5 and c.b < 0.55


## 邻域内是否有黄像素。
##
## 这里用**宽松**的判据而不是 _is_yellow_px：
## 一条 1 像素宽的横线如果落在两个像素行之间，两行各只有半亮，
## 严格判据会认为"没有黄"，从而把正确的渲染误判成缺陷。
## 宽松判据要求"暖色且明显偏红"，本图里只有黄色系（尺寸标注）能满足 ——
## 背景暗蓝灰、墙体近白、门窗淡蓝、文字淡绿都不会被误收。
func _yellow_near_px(img: Image, p: Vector2, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var x := int(p.x) + dx
			var y := int(p.y) + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if _is_warm_yellow(img.get_pixel(x, y)):
				return true
	return false


## 反向检查：图面上每一处黄色都必须落在尺寸标注层几何的附近。
##
## 上一条检查证明"每条尺寸线都画出来了"；这一条证明"没有凭空多出来的黄东西"。
## 两者方向相反，合起来才能同时兜住"漏画"和"画错地方"。
##
## 做法：把本层几何撒进 400mm 的方格并向外扩两格（容纳线宽、字高、抗锯齿），
## 再把黄像素反算成模型坐标去查格。落不进任何格子的，就是不该出现的黄。
##
## 阈值取 0.5%：修正后的基线是 0.00%（逐像素可重现），留一点余量即可；
## 阈值放宽到 2% 以上就接不住“少量黄画到了别处”这类回归了。
func _check_no_stray_yellow(vp) -> void:
	vp.exit_layout()
	# 清掉界面叠加物（捕捉标记 + 追踪对齐轴 + 十字光标）：
	# 它们是屏幕空间的 UI，画在鼠标位置上，不属于图纸内容。
	# 上一个检查（对象捕捉追踪）刻意把它们留着，这里必须先撤掉，
	# 否则黄色的追踪标记会被当成"越界的黄"误报。
	vp.cancel_command()
	vp._mouse_inside = false
	vp._last_snap = null
	vp.snap.clear_tracking()
	vp.view.center = Vector2(1800.0, 1500.0)
	vp.view.zoom = 0.0463
	vp.queue_redraw()
	await _settle()
	var img := await _shot("res://tests/out/_stray.png", "黄色越界")
	var doc := vp.doc as CadDocument
	var origin: Vector2 = (vp as CanvasItem).get_global_rect().position

	# 1) 把"允许出现黄色"的模型区域标出来
	const CELL := 400.0
	var cells := {}
	var geo := 0
	for e in doc.entities:
		if not e.visible or not doc.is_layer_visible(e.layer):
			continue
		if not _is_yellow_px(doc.resolve_color(e)):
			continue
		# 几何：沿每条曲线按半格步长补点。
		# 只标曲线的顶点是不够的 —— 一条长直线的中段离两个端点都很远，
		# 会把自己线上的像素判成"越界"（这个错我自己先犯过一次）。
		var curves := e.get_curves()
		for c in curves:
			var pts := c.tessellate(CELL * 0.5)
			for i in range(pts.size() - 1):
				var a := pts[i]
				var b := pts[i + 1]
				var n := maxi(1, int(ceilf(a.distance_to(b) / (CELL * 0.5))))
				for k in range(n + 1):
					_mark_cell(cells, a.lerp(b, float(k) / float(n)))
					geo += 1
		# 文字：按文字框铺点。文字形状取不到，只能按国标长仿宋估，
		# 因此宽高都留了余量，宁可放宽也不误报。
		var anns := e.get_annotation_texts()
		for ann in anns:
			_mark_text_box(cells, ann)
		# 展不开的图元（墙体轮廓、块引用）保守地取其包围盒端点
		if curves.is_empty() and anns.is_empty():
			var bb := e.get_bbox()
			_mark_cell(cells, bb.position)
			_mark_cell(cells, bb.end)

	# 2) 查每一个黄像素
	var total := 0
	var stray := 0
	var worst := Vector2.ZERO
	var worst_d := -1.0
	var strays: Array = []
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			if not _is_warm_yellow(img.get_pixel(x, y)):
				continue
			var m: Vector2 = vp.view.to_model(Vector2(x, y) - origin)
			if not vp.view.visible_rect().has_point(m):
				continue
			total += 1
			var k := _cell_of(m)
			if cells.has(k):
				continue
			stray += 1
			var d := _dist_to_marked(cells, k)
			if d > worst_d:
				worst_d = d
				worst = m
			_pile(strays, m)
	var ratio := 0.0 if total == 0 else float(stray) / float(total)
	print("[regression] 黄色越界：采样 %d 个黄像素（本层几何 %d 点），越界 %d 个（%.2f%%） %s" % [
		total, geo, stray, ratio * 100.0,
		"通过" if (total > 0 and ratio < 0.005) else "**失败：有多余的黄色画在了本层几何之外**"])
	if stray > 0:
		print("    最远处模型坐标 ≈ (%.0f, %.0f)，偏离标记区 %d 格（每格 %.0fmm）" % [
			worst.x, worst.y, int(worst_d), CELL])
		strays.sort_custom(func(p, q): return int(p[1]) > int(q[1]))
		for i in range(mini(strays.size(), 6)):
			var cl: Array = strays[i]
			var mp: Vector2 = cl[0] / float(cl[1])
			print("    第%d处 计数=%-4d 模型≈(%.0f, %.0f)" % [i + 1, int(cl[1]), mp.x, mp.y])


## 标记一格及其邻域（邻域用来容纳线宽、抗锯齿与取整误差）
func _mark_cell(cells: Dictionary, p: Vector2) -> void:
	var k := _cell_of(p)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			cells[Vector2i(k.x + dx, k.y + dy)] = true


func _cell_of(p: Vector2) -> Vector2i:
	const CELL := 400.0
	return Vector2i(int(floorf(p.x / CELL)), int(floorf(p.y / CELL)))


## 按文字框铺标记点。
## 文字的实际字形范围拿不到，这里按 GB/T 50001 的长仿宋字宽（字高的 0.7）估算，
## 并额外留 30% 余量；多行文字按行数与行距展开。锚点位置由对正方式决定。
func _mark_text_box(cells: Dictionary, ann: Dictionary) -> void:
	var anchor: Vector2 = ann.get("position", Vector2.ZERO)
	var th := float(ann.get("height", 0.0))
	if th <= 0.0:
		th = 350.0
	var txt := String(ann.get("text", ""))
	var rot := float(ann.get("rotation", 0.0))
	var lines := txt.split("\n")
	var longest := 0
	for ln in lines:
		longest = maxi(longest, String(ln).length())
	var w := float(longest) * th * 0.7 * 1.3 + th
	var h := th * 1.4 * float(maxi(lines.size(), 1))
	var dir := Vector2(cos(rot), sin(rot))
	var nrm := Vector2(-dir.y, dir.x)
	var a := int(ann.get("h_align", EntText.HAlign.LEFT))
	var start := anchor
	if a == EntText.HAlign.CENTER or a == EntText.HAlign.MIDDLE:
		start = anchor - dir * w * 0.5
	elif a == EntText.HAlign.RIGHT:
		start = anchor - dir * w
	var cols := int(w / 200.0) + 2
	for i in range(cols):
		var t := minf(float(i) * 200.0, w)
		for j in range(5):
			var o := (float(j) / 4.0 - 0.5) * h
			_mark_cell(cells, start + dir * t + nrm * o)


## 某格到最近"已标记格"的切比雪夫距离（格数），只搜附近 ±6 格
func _dist_to_marked(cells: Dictionary, k: Vector2i) -> float:
	for r in range(1, 7):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				if cells.has(Vector2i(k.x + dx, k.y + dy)):
					return float(r)
	return 99.0


## "暖黄"判据（宽松），用于判定**画面上**是否有黄色痕迹。
##
## 与 _is_yellow_px 的分工：
##   _is_yellow_px 判定"某个图元的颜色是不是尺寸标注黄"，要严格；
##   本判据判定"这个像素看起来是不是黄色痕迹"，必须容忍 1 像素宽的线
##   落在两行像素之间时各只有半亮的情况，因此阈值放宽。
##
## 两个必要条件把非黄色的暖色挡在外面：
##   r > b * 1.6  排除背景（暗蓝灰）、墙体（近白）、门窗（淡蓝）、文字（淡绿）
##   g > r * 0.55 排除 X 轴（0.55,0.22,0.22 的红）—— 它 r 也不小，
##                只看"偏红"会被它整条线混进来（曾经真的误判过）
func _is_warm_yellow(c: Color) -> bool:
	return c.r > 0.35 and c.r > c.b * 1.6 and c.g > c.r * 0.55


## 把散布的模型坐标按 800mm 聚成堆，用于报告"越界的黄都聚在哪里"
func _pile(acc: Array, m: Vector2) -> void:
	for cl in acc:
		var ctr: Vector2 = cl[0] / float(cl[1])
		if ctr.distance_to(m) < 800.0:
			cl[0] = cl[0] + m
			cl[1] = int(cl[1]) + 1
			return
	acc.append([m, 1])
