extends Node
## 性能基准。
##
## 目的不是"跑分"，而是找出十万级图元下的真实瓶颈，
## 为优化提供依据，并把结果留档以便后续回归对比。
##
## 运行（必须有窗口，无头模式没有渲染设备）：
##   godot --path <项目> --quit-after 6000 res://tests/bench.tscn

const SIZES := [10000, 50000, 100000]
## 图纸范围（mm）：按一层住宅平面放大到相当于几栋楼的体量
const SPAN := 120000.0


func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	# 等渲染管线就绪
	for i in range(6):
		await RenderingServer.frame_post_draw

	print("")
	print("════════════════════════════════════════════════════════════")
	print("  性能基准（Godot %s，模型单位 mm）" % Engine.get_version_info()["string"])
	print("════════════════════════════════════════════════════════════")

	for n in SIZES:
		await _bench_size(n)

	await _bench_hatch()
	await _bench_many_texts()

	print("")
	print("说明：")
	print("  · 拾取/框选的时间是单次操作耗时，CAD 交互要求 < 16ms（一帧）")
	print("  · 渲染一帧的耗时含视口剔除 + 分桶 + 提交，60fps 的预算是 16.7ms")
	print("  · 四叉树重建发生在每次文档变更后，故其耗时直接决定编辑手感")
	print("════════════════════════════════════════════════════════════")
	get_tree().quit(0)


func _bench_size(n: int) -> void:
	var doc := CadDocument.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260919
	var t0 := Time.get_ticks_usec()
	for i in range(n):
		var x := rng.randf_range(0.0, SPAN)
		var y := rng.randf_range(0.0, SPAN)
		var w := rng.randf_range(500.0, 6000.0)
		var e := EntLine.make(Vector2(x, y), Vector2(x + w, y))
		doc.add_entity(e, false)
	var t_add := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	var index := QuadTree.build(doc.entities, doc.get_bbox())
	var t_tree := Time.get_ticks_usec() - t0

	# 拾取：随机点取 200 次取平均
	var t1 := Time.get_ticks_usec()
	for i in range(200):
		var p := Vector2(rng.randf_range(0.0, SPAN), rng.randf_range(0.0, SPAN))
		CadSelection.pick(doc, index, p, 50.0)
	var t_pick := float(Time.get_ticks_usec() - t1) / 200.0

	# 框选：随机窗口 50 次取平均
	t1 = Time.get_ticks_usec()
	for i in range(50):
		var p := Vector2(rng.randf_range(0.0, SPAN), rng.randf_range(0.0, SPAN))
		CadSelection.crossing_select(doc, index, Rect2(p, Vector2(8000, 8000)))
	var t_cross := float(Time.get_ticks_usec() - t1) / 50.0

	# 渲染一帧
	var vp := CadViewport.new()
	vp.size = Vector2(1280, 720)
	add_child(vp)
	vp.setup(doc)
	vp.view.zoom_to_fit(doc.get_bbox())
	# 先跑一帧热身，再测 20 帧取平均
	vp.queue_redraw()
	await RenderingServer.frame_post_draw
	var t_snaps := PackedInt64Array()
	for i in range(20):
		var s := Time.get_ticks_usec()
		vp.queue_redraw()
		await RenderingServer.frame_post_draw
		t_snaps.append(Time.get_ticks_usec() - s)
	vp.queue_redraw()
	await RenderingServer.frame_post_draw
	var stats: Dictionary = vp.renderer.stats
	vp.queue_free()
	await get_tree().process_frame

	var t_render := _median(t_snaps)
	print("")
	print("── %d 个图元 ──" % n)
	print("  建文档        %8.1f ms" % (t_add / 1000.0))
	print("  四叉树重建    %8.1f ms   （每次编辑后触发）" % (t_tree / 1000.0))
	print("  单次拾取      %8.3f ms" % (t_pick / 1000.0))
	print("  单次框选      %8.3f ms   （窗口 8000x8000mm）" % (t_cross / 1000.0))
	print("  渲染一帧      %8.2f ms   （中位数，含剔除与提交）" % (t_render / 1000.0))
	print("  可见/剔除     %d / %d   线段 %d  批次 %d" % [
		int(stats.get("drawn", 0)), int(stats.get("culled", 0)),
		int(stats.get("segments", 0)), int(stats.get("buckets", 0))])


## 填充是计算最重的一类：图案要逐条生成并裁剪到边界内
func _bench_hatch() -> void:
	print("")
	print("── 图案填充（计算最重的图元）──")
	var doc := CadDocument.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# 50 个 6x6 米的混凝土填充
	for i in range(50):
		var x := rng.randf_range(0.0, 50000.0)
		var y := rng.randf_range(0.0, 50000.0)
		var pts := PackedVector2Array([
			Vector2(x, y), Vector2(x + 6000, y), Vector2(x + 6000, y + 6000), Vector2(x, y + 6000)])
		var h := EntHatch.make(pts, "钢筋混凝土")
		doc.add_entity(h, false)
	var t0 := Time.get_ticks_usec()
	var total := 0
	for e in doc.entities:
		total += (e as EntHatch).pattern_segments().size()
	var t_first := Time.get_ticks_usec() - t0
	# 缓存命中后的耗时
	t0 = Time.get_ticks_usec()
	for e in doc.entities:
		(e as EntHatch).pattern_segments()
	var t_cached := Time.get_ticks_usec() - t0
	print("  50 个 6x6m 填充，共 %d 个端点（%d 条线段）" % [total, total / 2])
	print("  首次生成      %8.1f ms   （含图案铺排与边界裁剪）" % (t_first / 1000.0))
	print("  缓存命中      %8.3f ms   （按边界与参数缓存，编辑时才重算）" % (t_cached / 1000.0))


## 文字是最费时的一类：每条文字一次独立绘制调用
func _bench_many_texts() -> void:
	print("")
	print("── 文字密集场景 ──")
	var doc := CadDocument.new()
	for i in range(2000):
		var x := float(i % 50) * 3000.0
		var y := float(i / 50) * 3000.0
		var t := EntText.make(Vector2(x, y), "房间名称 %d" % i, 350.0)
		t.h_align = EntText.HAlign.CENTER
		doc.add_entity(t, false)
	var vp := CadViewport.new()
	vp.size = Vector2(1280, 720)
	add_child(vp)
	vp.setup(doc)
	vp.view.zoom_to_fit(doc.get_bbox())
	vp.queue_redraw()
	await RenderingServer.frame_post_draw
	var snaps := PackedInt64Array()
	for i in range(20):
		var s := Time.get_ticks_usec()
		vp.queue_redraw()
		await RenderingServer.frame_post_draw
		snaps.append(Time.get_ticks_usec() - s)
	vp.queue_redraw()
	await RenderingServer.frame_post_draw
	var st: Dictionary = vp.renderer.stats
	vp.queue_free()
	await get_tree().process_frame
	print("  2000 条文字，渲染一帧 %8.2f ms（中位数）" % (_median(snaps) / 1000.0))
	print("  实际绘制文字 %d 条（屏幕字高不足 5px 的已跳过）" % int(st.get("texts_drawn", 0)))


static func _median(a: PackedInt64Array) -> float:
	if a.is_empty():
		return 0.0
	var b := Array(a)
	b.sort()
	return float(b[b.size() / 2])
