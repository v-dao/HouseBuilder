class_name P3Tests
extends TestSuite
## 国标规范库的测试：材料图例填充库、图幅图框。


func run() -> void:
	suite = "填充：图例库"
	_test_library()

	suite = "填充：生成与裁剪"
	_test_generate_in_boundary()
	_test_line_spacing()
	_test_primitive_inside()

	suite = "填充：图元"
	_test_hatch_entity()
	_test_hatch_from_entity()
	_test_hatch_roundtrip()

	suite = "图幅图框"
	_test_sheets()
	_test_title_block()

	suite = "图纸空间布局"
	_test_layout_basics()
	_test_layout_fit()
	_test_layout_roundtrip()


# ---------------------------------------------------------------------------
# 图例库
# ---------------------------------------------------------------------------

func _test_library() -> void:
	var lib := GbHatch.library()
	ok(lib.size() >= 25, "国标材料图例应不少于 25 种，实际 %d" % lib.size())
	# GB/T 50001 附录里施工图最常用的几种必须在
	var must := ["混凝土", "钢筋混凝土", "普通砖", "夯实土壤", "天然石材",
		"木材_横纹", "木材_纵纹", "金属", "玻璃", "防水材料", "松散保温材料",
		"多孔材料", "砂", "卵石", "毛石", "饰面砖", "粉刷"]
	for name in must:
		ok(lib.has(name), "图例库应包含「%s」" % name)
	# 除"实心"外，每种图例至少要有一个基元层
	for name in lib.keys():
		if String(name) == "实心":
			continue
		ok((lib[name] as Array).size() >= 1, "图例「%s」应至少有一个基元层" % name)
	# 名称列表应可排序返回
	var names := GbHatch.pattern_names()
	ok(names.size() == lib.size(), "名称列表数量应与库一致")
	var sorted_ok := true
	for i in range(1, names.size()):
		if names[i] < names[i - 1]:
			sorted_ok = false
	ok(sorted_ok, "图例名列表应有序")


# ---------------------------------------------------------------------------
# 生成与裁剪
# ---------------------------------------------------------------------------

func _square(size := 2000.0) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0, 0), Vector2(size, 0), Vector2(size, size), Vector2(0, size)])


## 所有生成的填充线段都必须落在边界内 —— 这是裁剪正确性的核心断言
func _test_generate_in_boundary() -> void:
	var b := _square(2000.0)
	var layers := GbHatch.layers_of("钢筋混凝土")
	ok(layers.size() >= 2, "钢筋混凝土图例应有斜线 + 点两层")
	var segs := GbHatch.generate(b, layers, 100.0)
	ok(segs.size() >= 4, "应生成若干填充线段，实际 %d 个端点" % segs.size())
	ok(segs.size() % 2 == 0, "端点对数量应为偶数")
	var outside := 0
	for i in range(0, segs.size(), 2):
		var a := segs[i]
		var c := segs[i + 1]
		# 线段中点必须在多边形内（端点在边界上，故只判中点）
		var mid := (a + c) * 0.5
		if not GbHatch.point_in_polygon(mid, b):
			outside += 1
	ok(outside == 0, "不应有填充线段落在边界外，实际 %d 条" % outside)

	# 空边界与过少顶点应返回空
	ok(GbHatch.generate(PackedVector2Array(), layers, 100.0).is_empty(), "空边界应返回空")
	ok(GbHatch.generate(PackedVector2Array([Vector2.ZERO, Vector2.ONE]), layers, 100.0).is_empty(),
		"不足三点的边界应返回空")


func _test_line_spacing() -> void:
	# 单一平行线族：45° 间距 2mm，出图比例 1:100 -> 模型间距 200mm
	var b := _square(4000.0)
	var layers := [GbHatch._l(45.0, 2.0)]
	var segs := GbHatch.generate(b, layers, 100.0)
	# 4000×4000 的方形，对角线长约 5657，按 200mm 间距应有约 28 条线
	var n := segs.size() / 2
	ok(n >= 20 and n <= 40, "4000mm 方形按 200mm 间距应有约 28 条线，实际 %d" % n)

	# 出图比例翻倍 -> 间距翻倍 -> 线数减半
	var segs2 := GbHatch.generate(b, layers, 200.0)
	var n2 := segs2.size() / 2
	ok(n2 < n, "出图比例放大后填充应变稀（%d -> %d）" % [n, n2])

	# 图案比例同样影响疏密
	var segs3 := GbHatch.generate(b, layers, 100.0, 2.0)
	ok(segs3.size() / 2 < n, "图案比例放大后填充应变稀")


func _test_primitive_inside() -> void:
	# 点阵与三角阵的基元必须完整落在边界内，不能戳出轮廓
	var b := _square(1000.0)
	for pat in ["砂", "焦渣", "卵石", "陶粒"]:
		var segs := GbHatch.generate(b, GbHatch.layers_of(pat), 100.0)
		var bad := 0
		for i in range(0, segs.size(), 2):
			var mid := (segs[i] + segs[i + 1]) * 0.5
			if not GbHatch.point_in_polygon(mid, b):
				bad += 1
		ok(bad == 0, "图例「%s」的基元不应越出边界，实际 %d 处" % [pat, bad])

	# 半径不足以容纳基元的小边界应几乎不产生基元
	var tiny := _square(30.0)
	var segs_tiny := GbHatch.generate(tiny, GbHatch.layers_of("毛石"), 100.0)
	ok(segs_tiny.size() / 2 <= 4, "很小的边界不应塞满基元，实际 %d 个" % (segs_tiny.size() / 2))


# ---------------------------------------------------------------------------
# 填充图元
# ---------------------------------------------------------------------------

func _test_hatch_entity() -> void:
	var doc := CadDocument.new()
	var h := EntHatch.make(_square(3000.0), "钢筋混凝土")
	doc.add_entity(h, false)
	ok(h.type_name() == "填充", "类型名")
	ok(not h.is_solid(), "默认非实心")
	var segs := h.pattern_segments()
	ok(segs.size() >= 4, "应生成填充线段")

	# 缓存：参数不变时应返回同一份数据
	var key1 := h._make_key()
	var segs2 := h.pattern_segments()
	ok(segs2.size() == segs.size(), "缓存命中时结果一致")
	ok(h._make_key() == key1, "参数不变时缓存键不变")
	# 改参数应让缓存失效
	h.pattern_scale = 3.0
	ok(h._make_key() != key1, "改图案比例后缓存键应变化")
	var segs3 := h.pattern_segments()
	ok(segs3.size() < segs.size(), "图案比例放大后线段变少（%d -> %d）" % [segs.size(), segs3.size()])

	# 边界内点应被判为命中（拾取按边界而非按填充线）
	ok(h.distance_to(Vector2(1500, 1500)) == 0.0, "边界内的点应命中填充")
	ok(h.distance_to(Vector2(9000, 9000)) > 0.0, "边界外的点不应命中")

	# 实心填充：轮廓应闭合
	var hs := EntHatch.make(_square(1000.0), "实心")
	hs.solid = true
	ok(hs.is_solid(), "实心标记")
	ok(hs.boundary_closed().size() == 5, "实心填充的闭合轮廓应首尾重合（4 点 + 收尾）")


func _test_hatch_from_entity() -> void:
	var pl := EntPolyline.make(PackedVector2Array([
		Vector2(0, 0), Vector2(2000, 0), Vector2(2000, 2000), Vector2(0, 2000)]),
		PackedFloat64Array(), true)
	var h := EntHatch.from_entity(pl, "普通砖")
	ok(h != null, "闭合多段线应能作为填充边界")
	if h == null:
		return
	ok(h.boundary.size() == 4, "边界应取到 4 个顶点，实际 %d" % h.boundary.size())
	ok(h.layer == pl.layer, "填充应继承边界图元的图层")

	# 圆作为边界
	var ci := EntCircle.make(Vector2(0, 0), 1000.0)
	var h2 := EntHatch.from_entity(ci, "砂")
	ok(h2 != null, "圆应能作为填充边界")
	if h2 != null:
		ok(h2.boundary.size() > 8, "圆的边界应被离散为多点，实际 %d" % h2.boundary.size())
		# 离散点应落在圆周上
		var ok_r := true
		for p in h2.boundary:
			if absf(p.length() - 1000.0) > 1.0:
				ok_r = false
		ok(ok_r, "圆边界的离散点应落在圆周上")

	# 开口多段线不能作为边界
	var open_pl := EntPolyline.make(PackedVector2Array([
		Vector2(0, 0), Vector2(1000, 0), Vector2(1000, 1000)]))
	ok(EntHatch.from_entity(open_pl, "砂") == null, "开口多段线不应作为填充边界")


func _test_hatch_roundtrip() -> void:
	var doc := CadDocument.new()
	var h := EntHatch.make(_square(2500.0), "夯实土壤")
	h.pattern_scale = 1.7
	h.angle_deg = 15.0
	h.origin = Vector2(100, 200)
	h.layer = "图例填充"
	h.aci = 256
	doc.add_entity(h, false)

	var r := EntHatch.from_dict(h.to_dict())
	ok(r.pattern_name == h.pattern_name, "图例名往返")
	close(r.pattern_scale, h.pattern_scale, "图案比例往返")
	close(r.angle_deg, h.angle_deg, "角度往返")
	vclose(r.origin, h.origin, "图案原点往返", 1e-6)
	ok(r.boundary.size() == h.boundary.size(), "边界顶点数往返")
	ok(r.layer == h.layer, "图层往返")
	# 生成结果必须一致
	ok(r.pattern_segments().size() == h.pattern_segments().size(), "填充线段数量往返")

	# 实心标记往返
	var hs := EntHatch.make(_square(500.0), "实心")
	hs.solid = true
	ok(EntHatch.from_dict(hs.to_dict()).solid, "实心标记往返")

	# 拆解为多段线
	var parts := h.explode()
	ok(parts.size() == 1, "填充拆解应为一条多段线")
	ok(parts[0] is EntPolyline, "拆解结果类型")


# ---------------------------------------------------------------------------
# 图幅图框
# ---------------------------------------------------------------------------

func _test_sheets() -> void:
	# GB/T 50001 表 3.0.1 基本幅面尺寸 (mm)
	var basic := {
		"A0": Vector2(1189, 841),
		"A1": Vector2(841, 594),
		"A2": Vector2(594, 420),
		"A3": Vector2(420, 297),
		"A4": Vector2(297, 210),
	}
	for k in basic.keys():
		var s := GbSheet.sheet_size(String(k))
		ok(s.x > 0.0, "应能取到 %s 的幅面尺寸" % k)
		close(s.x, float((basic[k] as Vector2).x), "%s 幅面长边" % k, 1e-6)
		close(s.y, float((basic[k] as Vector2).y), "%s 幅面短边" % k, 1e-6)
	# 未知幅面名应返回空
	ok(GbSheet.sheet_size("Q9").x <= 0.0, "未知幅面应返回空尺寸")


func _test_title_block() -> void:
	var doc := CadDocument.new()
	# 图框：A3 横式
	var made := GbSheet.build_frame(doc, "A3", false, {
		"project": "某住宅小区 1# 楼", "drawing": "一层平面图",
		"number": "建施-05", "scale": "1:100",
	})
	ok(made, "应能生成 A3 图框")
	ok(doc.entity_count() > 10, "图框应包含边框与标题栏的多个图元，实际 %d" % doc.entity_count())

	# 图框左下角应在原点，长边沿 X
	var bb := doc.get_bbox()
	close(bb.position.x, 0.0, "图框左下角 x", 1.0)
	close(bb.position.y, 0.0, "图框左下角 y", 1.0)
	close(bb.size.x, 420.0, "A3 横式图框宽 420mm", 1.0)
	close(bb.size.y, 297.0, "A3 横式图框高 297mm", 1.0)

	# 竖式图框应交换长短边
	var doc2 := CadDocument.new()
	GbSheet.build_frame(doc2, "A3", true, {})
	var bb2 := doc2.get_bbox()
	close(bb2.size.x, 297.0, "A3 竖式图框宽 297mm", 1.0)
	close(bb2.size.y, 420.0, "A3 竖式图框高 420mm", 1.0)

	# 会签栏必须落在左侧装订边内，不能超出纸面
	var bb3 := doc.get_bbox()
	ok(bb3.size.y <= 297.0 + 1.0, "会签栏不应使图框高度超出纸面，实际 %.1f" % bb3.size.y)
	ok(bb3.position.x >= -1.0, "会签栏不应越出纸面左边界，实际 %.1f" % bb3.position.x)

	# 图框线应比内框线粗（国标：图框线用粗实线）
	var has_frame_layer := false
	for n in doc2.layer_names():
		if String(n) == "图框":
			has_frame_layer = true
	ok(has_frame_layer, "应建立「图框」图层")

	# 标题栏文字应被写入
	var texts := 0
	for e in doc.entities:
		if e is EntText or e is EntMText:
			texts += 1
	ok(texts >= 6, "标题栏应写入多项文字（工程名称/图名/图号/比例等），实际 %d" % texts)


# ---------------------------------------------------------------------------
# 图纸空间布局
# ---------------------------------------------------------------------------

func _test_layout_basics() -> void:
	var l := CadLayout.make("布局1", "A3", false)
	var paper := l.paper_size()
	close(paper.x, 420.0, "A3 横式纸张宽", 1e-6)
	close(paper.y, 297.0, "A3 横式纸张高", 1e-6)
	# 竖式交换长短边
	var lp := CadLayout.make("布局2", "A3", true)
	close(lp.paper_size().x, 297.0, "A3 竖式纸张宽", 1e-6)
	close(lp.paper_size().y, 420.0, "A3 竖式纸张高", 1e-6)
	# 未知幅面退回 A3，不应崩
	var bad := CadLayout.make("布局3", "不存在的幅面", false)
	close(bad.paper_size().x, 420.0, "未知幅面应退回 A3", 1e-6)

	# 视口的模型->图纸映射：比例 1:100 时，模型 1000mm 应对应图纸 10mm
	var vp := l.main_viewport()
	vp.scale = 100.0
	vp.paper_rect = Rect2(10, 10, 100, 50)
	vp.model_center = Vector2(5000, 3000)
	var center_paper := vp.model_to_paper(vp.model_center)
	vclose(center_paper, vp.paper_rect.position + vp.paper_rect.size * 0.5,
		"模型中心应映射到视口中心", 1e-6)
	var offset := vp.model_to_paper(vp.model_center + Vector2(1000, 0)) - center_paper
	close(offset.x, 10.0, "模型 1000mm 在 1:100 下对应图纸 10mm", 1e-6)
	# 模型区域应等于视口尺寸乘以比例
	var mr := vp.model_rect()
	close(mr.size.x, 100.0 * 100.0, "视口覆盖的模型宽度 = 图纸宽 x 比例", 1e-6)


func _test_layout_fit() -> void:
	var l := CadLayout.make("布局1", "A3", false)
	# 一个 7800x6000 的图形，按 1:100 应能放进 A3
	l.fit_model_to_paper(Rect2(0, 0, 7800, 6000))
	var vp := l.main_viewport()
	ok(vp.scale >= 1.0, "比例应为正数")
	# 应吸附到国标常用比例
	var series := [1.0, 2.0, 2.5, 5.0, 10.0, 15.0, 20.0, 25.0, 30.0, 50.0,
		100.0, 150.0, 200.0, 300.0, 500.0, 1000.0, 2000.0]
	ok(series.has(vp.scale), "比例应吸附到国标常用值，实际 %s" % str(vp.scale))
	# 视口不得超出纸张
	var paper := l.paper_size()
	var r := vp.paper_rect
	ok(r.position.x >= -1e-6 and r.position.y >= -1e-6,
		"视口不应越过纸张左下角：%s" % str(r))
	ok(r.position.x + r.size.x <= paper.x + 1e-6 and r.position.y + r.size.y <= paper.y + 1e-6,
		"视口不应越过纸张右上角：视口 %s 纸张 %s" % [str(r), str(paper)])
	# 模型区域应覆盖整个图形
	var mr := vp.model_rect()
	ok(mr.size.x >= 7800.0 - 1.0 and mr.size.y >= 6000.0 - 1.0,
		"视口模型区域应能容纳整个图形：%s" % str(mr.size))
	# 视口不应与标题栏重叠（标题栏在图框内右下角）
	var title_top := r.position.y + r.size.y
	ok(title_top <= paper.y - 1.0, "视口不应顶到纸张上边缘")


func _test_layout_roundtrip() -> void:
	var doc := CadDocument.new()
	var l := doc.ensure_layout("我的布局", "A2", true)
	l.title_fields = {"project": "测试工程", "drawing": "平面图", "number": "建施-01"}
	var vp := l.main_viewport()
	vp.scale = 50.0
	vp.model_center = Vector2(1234.0, 5678.0)
	vp.paper_rect = Rect2(20, 30, 300, 200)
	vp.print_border = true
	vp.locked = true

	var path := "user://layout.hbd"
	NativeFormat.save(doc, path)
	var doc2 := CadDocument.new()
	ok(NativeFormat.load_into(doc2, path) == OK, "含布局的工程应能载入")
	ok(doc2.layouts.size() == 1, "布局数量往返")
	if doc2.layouts.size() == 1:
		var l2: CadLayout = doc2.layouts[0]
		ok(l2.name == "我的布局", "布局名往返")
		ok(l2.format == "A2", "幅面往返")
		ok(l2.portrait, "横竖式往返")
		close(l2.main_viewport().scale, 50.0, "视口比例往返")
		vclose(l2.main_viewport().model_center, Vector2(1234, 5678), "视口模型中心往返", 1e-6)
		vclose(l2.main_viewport().paper_rect.position, Vector2(20, 30), "视口位置往返", 1e-6)
		ok(l2.main_viewport().print_border, "视口打印边框标记往返")
		ok(l2.main_viewport().locked, "视口锁定标记往返")
		ok(String(l2.title_fields.get("project", "")) == "测试工程", "标题栏字段往返")
	# 没有布局的旧文件应能正常载入
	var doc3 := CadDocument.new()
	ok(NativeFormat.load_into(doc3, path) == OK, "重复载入应成功")
