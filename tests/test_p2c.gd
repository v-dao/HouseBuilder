class_name P2cTests
extends TestSuite
## 国标符号图元的测试。
##
## 符号的尺寸都以"图纸上的毫米"标注在国标里，落到模型空间必须乘出图比例。
## 这个换算一旦漏掉，符号在 1:100 图上会小到看不见 —— 是这一族图元最容易犯的错，
## 因此每个符号都断言一次实际尺寸。


func run() -> void:
	suite = "符号：标高"
	_test_elevation()
	_test_elevation_format()

	suite = "符号：索引与详图"
	_test_index_and_detail()

	suite = "符号：剖切"
	_test_section()

	suite = "符号：引出线"
	_test_leader()

	suite = "符号：折断线与波浪线"
	_test_break_line()

	suite = "符号：轴线号"
	_test_axis_bubble()

	suite = "符号：比例与往返"
	_test_scale_factor()
	_test_symbol_roundtrip()


func _doc() -> CadDocument:
	return CadDocument.new()


func _seg_len(c: GeoCurve) -> float:
	return c.curve_length()


# ---------------------------------------------------------------------------
# 标高
# ---------------------------------------------------------------------------

func _test_elevation() -> void:
	var doc := _doc()
	var e := EntSymbols.Elevation.make(Vector2(1000, 2000), 3600.0)
	doc.add_entity(e, false)
	var cs := e.get_curves()
	ok(cs.size() == 3, "标高符号应由三角形三条边组成，实际 %d" % cs.size())
	# 三角形的高应为 3mm × 100 = 300mm
	var scale := doc.plot_scale
	close(scale, 100.0, "默认出图比例 1:100")
	var h := e.mm(3.0)
	close(h, 300.0, "三角形高度 3mm 换算到模型为 300mm", 1e-6)
	# 尖端（apex）在 position，底边在 position + (0, h)
	var has_apex := false
	var base_y := -1.0
	for c in cs:
		var s := c as GeoSeg
		if s.a.distance_to(e.position) < 1e-6 or s.b.distance_to(e.position) < 1e-6:
			has_apex = true
		if absf(s.a.y - s.b.y) < 1e-6:
			base_y = s.a.y
	ok(has_apex, "三角形尖端应落在标注位置上")
	close(base_y, e.position.y + h, "三角形底边应在尖端上方 300mm 处", 1e-3)

	# flip 时三角形应翻到下方
	var e2 := EntSymbols.Elevation.make(Vector2(0, 0), -450.0, true)
	var base_y2 := -1.0
	for c in e2.get_curves():
		var s := c as GeoSeg
		if absf(s.a.y - s.b.y) < 1e-6:
			base_y2 = s.a.y
	close(base_y2, -h, "flip 时三角形底边应在尖端下方", 1e-3)


func _test_elevation_format() -> void:
	# GB：标高数字以米为单位、三位小数；零点注成 ±0.000
	ok(EntSymbols.Elevation.format_elevation(0.0) == "±0.000", "零标高应注成 ±0.000")
	ok(EntSymbols.Elevation.format_elevation(3600.0) == "3.600", "3600mm 应为 3.600")
	ok(EntSymbols.Elevation.format_elevation(-450.0) == "-0.450", "负标高应带负号")
	ok(EntSymbols.Elevation.format_elevation(1200.0) == "1.200", "1200mm 应为 1.200")
	# 极小的非零值也应视为零点
	ok(EntSymbols.Elevation.format_elevation(0.2) == "±0.000", "0.2mm 应视为零点")
	# 文字注记的字高也按比例换算
	var e := EntSymbols.Elevation.make(Vector2.ZERO, 3600.0)
	var anns := e.get_annotation_texts()
	ok(anns.size() == 1, "标高应产生一条文字注记")
	if anns.size() == 1:
		ok(String(anns[0]["text"]) == "3.600", "注记内容")
		close(float(anns[0]["height"]), 250.0, "标高数字字高 2.5mm × 100 = 250mm", 1e-6)


# ---------------------------------------------------------------------------
# 索引 / 详图
# ---------------------------------------------------------------------------

func _test_index_and_detail() -> void:
	var doc := _doc()
	var idx := EntSymbols.IndexMark.make_index(Vector2(0, 0), "3", "建施-05")
	doc.add_entity(idx, false)
	# 图纸上直径 10mm -> 半径 5mm；1:100 时模型空间半径为 5 x 100 = 500mm
	close(idx.radius(), 500.0, "索引符号圆半径 5mm -> 模型 500mm", 1e-6)
	# 索引符号：圆 + 水平直径 = 2 条曲线
	ok(idx.get_curves().size() == 2, "索引符号应为圆 + 水平直径，实际 %d" % idx.get_curves().size())
	var anns := idx.get_annotation_texts()
	ok(anns.size() == 2, "索引符号应有上下两个编号，实际 %d" % anns.size())
	if anns.size() == 2:
		# 上半圆编号在圆心的上方
		var p_top: Vector2 = anns[0]["position"]
		ok(p_top.y > 0.0, "上部编号应在圆心上方，实际 y=%.2f" % p_top.y)
		ok(String(anns[0]["text"]) == "3" and String(anns[1]["text"]) == "建施-05",
			"上下编号内容与顺序")

	var det := EntSymbols.IndexMark.make_detail(Vector2(0, 0), "3", "")
	doc.add_entity(det, false)
	close(det.radius(), 700.0, "详图符号圆半径 7mm -> 模型 700mm", 1e-6)
	ok(det.get_curves().size() == 2, "详图符号应为圆 + 水平直径")
	# 仅有上部编号时只产生一条注记
	ok(det.get_annotation_texts().size() == 1, "详图符号只填上部编号时应只有一条注记")

	# 带引线的索引符号
	var idx2 := EntSymbols.IndexMark.make_index(Vector2(0, 0), "5", "建施-08")
	idx2.has_leader = true
	idx2.leader_to = Vector2(-2000, 1500)
	ok(idx2.get_curves().size() == 3, "带引线的索引符号应有 3 条曲线")


# ---------------------------------------------------------------------------
# 剖切
# ---------------------------------------------------------------------------

func _test_section() -> void:
	var doc := _doc()
	# 剖切位置线沿 Y 方向，投射方向朝左（side=1 对应 p1->p2 的左侧）
	var m := EntSymbols.SectionMark.make(Vector2(0, 0), Vector2(0, 8000), 1, "1")
	doc.add_entity(m, false)
	var cs := m.get_curves()
	ok(cs.size() == 3, "剖切符号应为剖切位置线 + 两端投射方向线，实际 %d" % cs.size())
	# 剖切位置线：p1 到 p2
	var found_pos := false
	for c in cs:
		var s := c as GeoSeg
		if s.a.distance_to(Vector2(0, 0)) < 1e-6 and s.b.distance_to(Vector2(0, 8000)) < 1e-6:
			found_pos = true
	ok(found_pos, "应存在从 p1 到 p2 的剖切位置线")
	# 投射方向线长 5mm × 100 = 500mm，且垂直于剖切位置线
	var dir_len := m.mm(5.0)
	close(dir_len, 500.0, "投射方向线长 5mm -> 模型 500mm", 1e-6)
	for c in cs:
		var s := c as GeoSeg
		var v := s.b - s.a
		if absf(v.length() - dir_len) < 1e-3:
			# 剖切位置线沿 +Y，其左侧为 -X
			close(v.x, -dir_len, "投射方向线应垂直于剖切位置线并指向左侧", 1e-3)
	# 编号注记应有两条，分别在两端
	ok(m.get_annotation_texts().size() == 2, "剖切符号两端应各有一个编号")


# ---------------------------------------------------------------------------
# 引出线
# ---------------------------------------------------------------------------

func _test_leader() -> void:
	var doc := _doc()
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(1000, 800), Vector2(3000, 800)])
	var l := EntSymbols.Leader.make(pts, "外墙保温做法见详图")
	doc.add_entity(l, false)
	var cs := l.get_curves()
	# 2 条折线段 + 3 条箭头边 = 5
	ok(cs.size() == 5, "带箭头的引出线应为 2 段折线 + 3 条箭头边，实际 %d" % cs.size())
	var anns := l.get_annotation_texts()
	ok(anns.size() == 1, "引出线应产生一条文字注记")
	if anns.size() == 1:
		vclose(anns[0]["position"], pts[2], "文字应注写在折线末端")
		close(float(anns[0]["height"]), 350.0, "引出线文字字高 3.5mm × 100", 1e-6)
	# 末段为水平时文字不旋转
	var l2 := EntSymbols.Leader.make(PackedVector2Array([Vector2(0, 0), Vector2(1000, 0)]), "x")
	close(float(l2.get_annotation_texts()[0]["rotation"]), 0.0, "末段水平时文字不旋转")


# ---------------------------------------------------------------------------
# 折断线 / 波浪线
# ---------------------------------------------------------------------------

func _test_break_line() -> void:
	var doc := _doc()
	var bl := EntSymbols.BreakLine.make(Vector2(0, 0), Vector2(6000, 0))
	doc.add_entity(bl, false)
	var cs := bl.get_curves()
	ok(cs.size() == 1, "折断线应为一条多段线")
	ok(cs[0].kind() == GeoCurve.Kind.POLY, "折断线应以多段线表达")
	var pts := cs[0].tessellate(0.01)
	ok(pts.size() >= 6, "直线折断的 Z 字形至少需要 6 个顶点，实际 %d" % pts.size())
	# 起点与终点必须精确落在给定位置
	vclose(pts[0], Vector2(0, 0), "折断线起点", 1e-6)
	vclose(pts[pts.size() - 1], Vector2(6000, 0), "折断线终点", 1e-6)
	# Z 字形的偏移量应为 2 × 幅度 = 2 × 1.5mm × 100 = 300mm
	var max_dev := 0.0
	for p in pts:
		max_dev = maxf(max_dev, absf(p.y))
	ok(max_dev > 0.0, "折断线中段应有 Z 字形偏移")
	close(max_dev, 300.0, "Z 字形偏移量 = 2 × 1.5mm × 100", 1.0)

	# 波浪线：两端收拢到给定端点，中间有波动
	var wl := EntSymbols.BreakLine.make(Vector2(0, 0), Vector2(6000, 0), true)
	doc.add_entity(wl, false)
	var wpts := wl.get_curves()[0].tessellate(0.01)
	vclose(wpts[0], Vector2(0, 0), "波浪线起点", 1e-6)
	vclose(wpts[wpts.size() - 1], Vector2(6000, 0), "波浪线终点", 1e-6)
	var w_dev := 0.0
	for p in wpts:
		w_dev = maxf(w_dev, absf(p.y))
	ok(w_dev > 0.0, "波浪线应有波动")
	ok(w_dev <= 150.0 + 1e-6, "波浪线幅度不应超过 1.5mm × 100 = 150mm，实际 %.1f" % w_dev)
	# 端点处收拢为 0 偏移
	close(absf(wpts[0].y), 0.0, "波浪线端点应无偏移", 1e-6)


# ---------------------------------------------------------------------------
# 轴线号
# ---------------------------------------------------------------------------

func _test_axis_bubble() -> void:
	var doc := _doc()
	var b := EntSymbols.AxisBubble.make(Vector2(0, 9000), "3")
	doc.add_entity(b, false)
	close(b.radius(), 500.0, "轴线号圆半径 5mm -> 模型 500mm", 1e-6)
	var cs := b.get_curves()
	ok(cs.size() == 1 and cs[0].kind() == GeoCurve.Kind.ARC, "轴线号应为一个圆")
	close((cs[0] as GeoArc).sweep(), TAU, "轴线号圆应为整圆", 1e-6)
	var anns := b.get_annotation_texts()
	ok(anns.size() == 1, "轴线号应有一条编号注记")
	if anns.size() == 1:
		ok(String(anns[0]["text"]) == "3", "编号内容")
		vclose(anns[0]["position"], b.position, "编号应居中于圆心")
		ok(int(anns[0]["v_align"]) == EntText.VAlign.MIDDLE, "编号应垂直居中")


# ---------------------------------------------------------------------------
# 比例与往返
# ---------------------------------------------------------------------------

## 出图比例必须影响所有符号尺寸。
## 1:100 与 1:50 下同一个标高符号的几何大小应差一倍。
func _test_scale_factor() -> void:
	var doc := _doc()
	var e := EntSymbols.Elevation.make(Vector2.ZERO, 0.0)
	doc.add_entity(e, false)
	var h100 := e.mm(3.0)
	close(h100, 300.0, "1:100 时 3mm 对应 300mm", 1e-6)

	doc.plot_scale = 50.0
	var h50 := e.mm(3.0)
	close(h50, 150.0, "1:50 时 3mm 对应 150mm", 1e-6)
	ok(absf(h100 / h50 - 2.0) < 1e-9, "1:100 与 1:50 的符号尺寸应成 2 倍关系")

	# 脱离文档时应退回 1:100
	var orphan := EntSymbols.Elevation.make(Vector2.ZERO, 0.0)
	close(orphan.mm(3.0), 300.0, "脱离文档时按 1:100 处理", 1e-6)


func _test_symbol_roundtrip() -> void:
	var doc := _doc()
	var src: Array[CadEntity] = [
		EntSymbols.Elevation.make(Vector2(100, 200), -450.0, true),
		EntSymbols.IndexMark.make_index(Vector2(0, 0), "3", "建施-05"),
		EntSymbols.IndexMark.make_detail(Vector2(500, 500), "7", ""),
		EntSymbols.SectionMark.make(Vector2(0, 0), Vector2(0, 8000), -1, "2"),
		EntSymbols.Leader.make(PackedVector2Array([Vector2(0, 0), Vector2(1000, 500)]), "说明"),
		EntSymbols.BreakLine.make(Vector2(0, 0), Vector2(6000, 0), true),
		EntSymbols.AxisBubble.make(Vector2(0, 9000), "B"),
	]
	for e: CadEntity in src:
		e.layer = "尺寸标注"
		e.aci = 256
		doc.add_entity(e, false)
		var d := e.to_dict()
		var r := EntSymbols.from_dict(d)
		ok(r != null, "%s 应能从字典重建" % (e as EntSymbols.Base).kind_name())
		if r == null:
			continue
		ok(r.layer == e.layer, "%s 图层往返" % (e as EntSymbols.Base).kind_name())
		var a := e.get_bbox()
		var b := r.get_bbox()
		ok(a.position.distance_to(b.position) <= 1e-3 and a.size.distance_to(b.size) <= 1e-3,
			"%s 包围盒往返 (%.2f,%.2f)+/-(%.2f,%.2f) vs (%.2f,%.2f)+/-(%.2f,%.2f)" % [
				(e as EntSymbols.Base).kind_name(),
				a.position.x, a.position.y, a.size.x, a.size.y,
				b.position.x, b.position.y, b.size.x, b.size.y])
		# 文字注记数量也必须一致
		ok(r.get_annotation_texts().size() == e.get_annotation_texts().size(),
			"%s 文字注记数量往返" % (e as EntSymbols.Base).kind_name())
