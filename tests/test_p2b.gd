class_name P2bTests
extends TestSuite
## 尺寸标注的测试。
##
## 重点验证 GB/T 50001 第 11 章的几何要求：
## 尺寸界线超出量、45° 斜短线起止符号、尺寸数字在尺寸线上方中部、
## 竖直尺寸的字头朝左、以及所有标注元素随出图比例放大。


func run() -> void:
	suite = "尺寸标注：线性"
	_test_linear_horizontal()
	_test_linear_vertical()
	_test_linear_axis_choice()

	suite = "尺寸标注：对齐"
	_test_aligned()

	suite = "尺寸标注：半径与直径"
	_test_radial()

	suite = "尺寸标注：角度"
	_test_angular()

	suite = "尺寸标注：文字"
	_test_text_placement()
	_test_text_height_scaling()

	suite = "尺寸标注：箭头方向"
	_test_arrow_direction()

	suite = "尺寸标注：其他"
	_test_explode_and_roundtrip()


## 建一个带国标标注样式的文档
func _doc() -> CadDocument:
	var doc := CadDocument.new()
	return doc


func _dim(doc: CadDocument, d: EntDim) -> EntDim:
	d.dim_style_name = "国标-1:100"
	d.text_style_name = "标注_2.5"
	doc.add_entity(d, false)
	return d


## 取标注几何中所有线段，便于逐条断言
func _segs(d: EntDim) -> Array[GeoSeg]:
	var out: Array[GeoSeg] = []
	for c in d.get_curves():
		if c.kind() == GeoCurve.Kind.SEG:
			out.append(c as GeoSeg)
	return out


# ---------------------------------------------------------------------------
# 线性
# ---------------------------------------------------------------------------

func _test_linear_horizontal() -> void:
	var doc := _doc()
	# 量 3600，尺寸线放在下方 500 处
	var d := _dim(doc, EntDim.make_linear(Vector2(0, 0), Vector2(3600, 0), Vector2(1800, -500)))
	ok(d._linear_axis() == 0, "尺寸线在下方时应判为水平标注")
	close(d.measured_value(), 3600.0, "实测值 3600")
	ok(d.display_text() == "3600", "显示文字应为 3600，实际 %s" % d.display_text())

	var segs := _segs(d)
	# 2 条尺寸界线 + 1 条尺寸线 + 2 个斜短线 = 5 段
	ok(segs.size() == 5, "水平标注应产生 5 条线段，实际 %d" % segs.size())

	# 尺寸线：从 (0,-500) 到 (3600,-500)
	var found_dim_line := false
	for s in segs:
		if s.a.distance_to(Vector2(0, -500)) < 1e-4 and s.b.distance_to(Vector2(3600, -500)) < 1e-4:
			found_dim_line = true
	ok(found_dim_line, "应存在从 (0,-500) 到 (3600,-500) 的尺寸线")

	# 尺寸界线超出尺寸线 2~3mm，1:100 时应为 250mm
	var st := d.style()
	close(st.overall_scale, 100.0, "国标-1:100 样式的出图比例为 100")
	var ext_len := -1.0
	for s in segs:
		for e in [s.a, s.b]:
			if absf(e.x) < 1e-4 and e.y < -500.0:
				ext_len = absf(e.y)
	ok(ext_len > 0.0, "应找到左侧尺寸界线的外端")
	close(ext_len, 500.0 + st.scaled(st.ext_line_extension),
		"左侧尺寸界线外端应在尺寸线下方 250mm 处", 1e-3)

	# 45° 斜短线：与尺寸线成 45°，总长 = terminator_size × 比例
	var tick_len := -1.0
	for s in segs:
		var v := s.b - s.a
		if v.length() > 1.0 and v.length() < st.scaled(st.terminator_size) * 2.0:
			tick_len = v.length()
			# 水平标注的斜短线应与 X 轴成 45°
			close(absf(rad_to_deg(v.angle())), 45.0, "斜短线应与尺寸线成 45°", 1e-4)
			break
	ok(tick_len > 0.0, "应找到 45° 斜短线")
	close(tick_len, st.scaled(st.terminator_size), "斜短线长度按出图比例放大", 1e-3)


func _test_linear_vertical() -> void:
	var doc := _doc()
	# 量 3000，尺寸线放在左侧 800 处
	var d := _dim(doc, EntDim.make_linear(Vector2(0, 0), Vector2(0, 3000), Vector2(-800, 1500)))
	ok(d._linear_axis() == 1, "尺寸线在侧方时应判为竖直标注")
	close(d.measured_value(), 3000.0, "竖直标注实测值 3000")

	var segs := _segs(d)
	var found := false
	for s in segs:
		if s.a.distance_to(Vector2(-800, 0)) < 1e-4 and s.b.distance_to(Vector2(-800, 3000)) < 1e-4:
			found = true
	ok(found, "应存在竖直尺寸线 (-800,0)-(-800,3000)")


func _test_linear_axis_choice() -> void:
	# 尺寸线拖到正上方 -> 水平标注
	var dh := EntDim.make_linear(Vector2(0, 0), Vector2(3600, 100), Vector2(1800, 2000))
	ok(dh._linear_axis() == 0, "尺寸线在上方时应为水平标注")
	close(dh.measured_value(), 3600.0, "水平标注量取 Δx", 1e-6)
	# 尺寸线拖到正侧方 -> 竖直标注
	var dv := EntDim.make_linear(Vector2(0, 0), Vector2(3600, 100), Vector2(-3000, 50))
	ok(dv._linear_axis() == 1, "尺寸线在侧方时应为竖直标注")
	close(dv.measured_value(), 100.0, "竖直标注量取 Δy", 1e-6)


# ---------------------------------------------------------------------------
# 对齐
# ---------------------------------------------------------------------------

func _test_aligned() -> void:
	var doc := _doc()
	# 3-4-5 直角三角形：真实距离 500
	var d := _dim(doc, EntDim.make_aligned(Vector2(0, 0), Vector2(300, 400), Vector2(-100, 100)))
	close(d.measured_value(), 500.0, "对齐标注量取真实距离", 1e-5)
	ok(d.display_text() == "500", "对齐标注文字，实际 %s" % d.display_text())
	# 尺寸线必须平行于两点连线
	var segs := _segs(d)
	var dir := (Vector2(300, 400) - Vector2.ZERO).normalized()
	var found := false
	for s in segs:
		var v := (s.b - s.a)
		if v.length() > 100.0:
			var u := v.normalized()
			if absf(absf(u.dot(dir)) - 1.0) < 1e-5:
				found = true
	ok(found, "尺寸线应平行于两点连线")


# ---------------------------------------------------------------------------
# 半径与直径
# ---------------------------------------------------------------------------

func _test_radial() -> void:
	var doc := _doc()
	var c := Vector2(1000, 2000)
	var r := 500.0
	var d := _dim(doc, EntDim.make_radius(c, c + Vector2(r, 0), c + Vector2(r * 2.0, 0)))
	close(d.measured_value(), r, "半径实测值")
	ok(d.display_text() == "R500", "半径文字应带 R 前缀，实际 %s" % d.display_text())
	var segs := _segs(d)
	ok(segs.size() >= 3, "半径标注应有引线与箭头，实际 %d 段" % segs.size())
	# 引线应从圆心指向圆弧点
	var has_leader := false
	for s in segs:
		if s.a.distance_to(c) < 1e-4 and s.b.distance_to(c + Vector2(r, 0)) < 1e-4:
			has_leader = true
	ok(has_leader, "半径引线应自圆心引出到圆弧")

	var d2 := _dim(doc, EntDim.make_diameter(c, c + Vector2(0, r), c + Vector2(0, r * 2.0)))
	close(d2.measured_value(), r * 2.0, "直径实测值为两倍半径")
	ok(d2.display_text() == "⌀1000", "直径文字应带 ⌀ 前缀，实际 %s" % d2.display_text())
	var segs2 := _segs(d2)
	# 直径线应贯穿圆心
	var through := false
	for s in segs2:
		var mid := (s.a + s.b) * 0.5
		if s.a.distance_to(c + Vector2(0, -r)) < 1e-3 and s.b.distance_to(c + Vector2(0, r)) < 1e-3:
			through = true
	ok(through, "直径线应贯穿圆心，连接圆上两点")


# ---------------------------------------------------------------------------
# 角度
# ---------------------------------------------------------------------------

func _test_angular() -> void:
	var doc := _doc()
	var d := _dim(doc, EntDim.make_angular(Vector2(0, 0), Vector2(100, 0), Vector2(0, 100), Vector2(60, 60)))
	close(d.measured_value(), 90.0, "直角的角度标注为 90°", 1e-4)
	ok(d.display_text() == "90°", "角度文字应带度符号，实际 %s" % d.display_text())
	var curves := d.get_curves()
	var has_arc := false
	for c in curves:
		if c.kind() == GeoCurve.Kind.ARC:
			has_arc = true
			var a := c as GeoArc
			close(a.sweep(), PI * 0.5, "角度标注的圆弧扫掠角应为 90°", 1e-4)
	ok(has_arc, "角度标注应有圆弧")

	# 钝角：120°
	var d2 := _dim(doc, EntDim.make_angular(Vector2(0, 0), Vector2(100, 0),
		Vector2(cos(deg_to_rad(120.0)), sin(deg_to_rad(120.0))) * 100.0, Vector2(30, 30)))
	close(d2.measured_value(), 120.0, "钝角标注为 120°", 1e-3)


# ---------------------------------------------------------------------------
# 文字
# ---------------------------------------------------------------------------

func _test_text_placement() -> void:
	var doc := _doc()
	# 水平标注：文字应在尺寸线上方（y 更大）
	var dh := _dim(doc, EntDim.make_linear(Vector2(0, 0), Vector2(3600, 0), Vector2(1800, -500)))
	var th := dh.text_position()
	ok(th.y > -500.0, "水平标注的文字应在尺寸线上方，实际 y=%.1f" % th.y)
	close(th.x, 1800.0, "文字应在尺寸线中点（x 方向）", 1e-4)
	close(dh._text_angle(), 0.0, "水平标注文字不旋转")

	# 竖直标注：文字应在尺寸线左侧（x 更小），且旋转 90°（字头朝左）
	var dv := _dim(doc, EntDim.make_linear(Vector2(0, 0), Vector2(0, 3000), Vector2(-800, 1500)))
	var tv := dv.text_position()
	ok(tv.x < -800.0, "竖直标注的文字应在尺寸线左侧，实际 x=%.1f" % tv.x)
	close(tv.y, 1500.0, "文字应在尺寸线中点（y 方向）", 1e-4)
	close(dv._text_angle(), PI * 0.5, "竖直标注文字应旋转 90°", 1e-6)

	# 尺寸线朝下时角度仍应归一化到 [0,180)，保证文字可读
	var d3 := _dim(doc, EntDim.make_linear(Vector2(0, 3000), Vector2(0, 0), Vector2(-800, 1500)))
	var a3 := d3._text_angle()
	ok(a3 >= 0.0 and a3 < PI, "文字角度应归一化到 [0,180)，实际 %.1f°" % rad_to_deg(a3))
	close(a3, PI * 0.5, "反向的竖直标注文字角度仍应为 90°", 1e-6)


## 尺寸数字的字高必须按出图比例放大，否则 1:100 图上小到看不见
func _test_text_height_scaling() -> void:
	var doc := _doc()
	var d := _dim(doc, EntDim.make_linear(Vector2(0, 0), Vector2(3600, 0), Vector2(1800, -500)))
	var anns := d.get_annotation_texts()
	ok(anns.size() == 1, "线性标注应产生一条文字注记")
	if anns.size() != 1:
		return
	var st := d.style()
	close(st.text_height, 2.5, "国标-1:100 样式图纸字高为 2.5mm")
	close(float(anns[0]["height"]), 250.0, "模型空间字高应为 2.5×100 = 250mm", 1e-3)
	ok(String(anns[0]["text"]) == "3600", "注记文字内容")
	ok(String(anns[0]["style"]) == "标注_2.5", "注记使用的文字样式")
	ok(int(anns[0]["h_align"]) == EntText.HAlign.CENTER, "尺寸数字应水平居中")
	ok(int(anns[0]["v_align"]) == EntText.VAlign.BOTTOM, "尺寸数字应底部对齐（即位于尺寸线上方）")


# ---------------------------------------------------------------------------
# 拆解与往返
# ---------------------------------------------------------------------------

func _test_explode_and_roundtrip() -> void:
	var doc := _doc()
	var d := _dim(doc, EntDim.make_linear(Vector2(0, 0), Vector2(3600, 0), Vector2(1800, -500)))
	var parts := d.explode()
	ok(parts.size() >= 6, "线性标注拆解后应有 5 段线 + 1 个文字，实际 %d" % parts.size())
	var texts := 0
	for p in parts:
		if p is EntText:
			texts += 1
	ok(texts == 1, "拆解后应恰好有 1 个文字图元，实际 %d" % texts)

	# 序列化往返
	d.layer = "尺寸标注"
	d.aci = 256
	var d2 := EntDim.from_dict(d.to_dict())
	ok(d2.dim_type == d.dim_type, "标注类型往返")
	ok(d2.dim_style_name == d.dim_style_name, "标注样式名往返")
	ok(d2.layer == d.layer, "图层往返")
	vclose(d2.p1, d.p1, "p1 往返", 1e-6)
	vclose(d2.line_pos, d.line_pos, "line_pos 往返", 1e-6)
	var a := d.get_bbox()
	var b := d2.get_bbox()
	ok(a.position.distance_to(b.position) <= 1e-3 and a.size.distance_to(b.size) <= 1e-3,
		"包围盒往返 (%.2f,%.2f)+/-(%.2f,%.2f) vs (%.2f,%.2f)+/-(%.2f,%.2f)" % [
			a.position.x, a.position.y, a.size.x, a.size.y,
			b.position.x, b.position.y, b.size.x, b.size.y])

	# 文字覆盖值
	var d3 := EntDim.make_linear(Vector2(0, 0), Vector2(3600, 0), Vector2(1800, -500))
	d3.text_override = "见详图"
	ok(d3.display_text() == "见详图", "文字覆盖值应优先生效")


## 箭头必须指向被标注的圆弧，箭尖落在圆弧上。
## 这个方向极易写反（本实现第一版就反了），故单独钉死。
func _test_arrow_direction() -> void:
	var doc := _doc()
	var c := Vector2(0, 0)
	var arc_pt := Vector2(500, 0)
	var d := _dim(doc, EntDim.make_radius(c, arc_pt, Vector2(1000, 0)))
	var st := d.style()
	var a := st.scaled(st.arrow_size)
	# 把箭头拆成"朝向精确点等于其反射"的形状：先确认精确点与圆心重合
	# 注意：引线的一个端点也在圆弧点上，不能只按"端点在圆弧点"来识别翼边，
	# 否则会把引线算成一条翼边（长度等于半径）。必须再用长度区分。
	var expect_len := a * sqrt(1.0 + 0.32 * 0.32)
	var wings := 0
	for s in _segs(d):
		var far := -1.0
		if s.a.distance_to(arc_pt) < 1e-4:
			far = s.b.distance_to(arc_pt)
		elif s.b.distance_to(arc_pt) < 1e-4:
			far = s.a.distance_to(arc_pt)
		if far < 0.0:
			continue
		if absf(far - expect_len) > 1e-2:
			continue
		wings += 1
		var other := s.b if s.a.distance_to(arc_pt) < 1e-4 else s.a
		ok(other.x <= arc_pt.x + 1e-6, "翼边应朝引线后方延伸，不越过圆弧点")
	ok(wings == 2, "应有两条翼边自箭尖引出，实际 %d" % wings)

	# 直径标注：两端各一个箭头，且都指向外侧的圆弧
	var d2 := _dim(doc, EntDim.make_diameter(c, arc_pt, Vector2(1000, 0)))
	var left := c - Vector2(500, 0)
	var right := arc_pt
	var left_wings := 0
	var right_wings := 0
	for s in _segs(d2):
		for probe in [left, right]:
			var far := -1.0
			if s.a.distance_to(probe) < 1e-4:
				far = s.b.distance_to(probe)
			elif s.b.distance_to(probe) < 1e-4:
				far = s.a.distance_to(probe)
			if far < 0.0 or absf(far - expect_len) > 1e-2:
				continue
			if probe == left:
				left_wings += 1
			else:
				right_wings += 1
	ok(left_wings == 2, "直径标注左端应有两条翼边，实际 %d" % left_wings)
	ok(right_wings == 2, "直径标注右端应有两条翼边，实际 %d" % right_wings)

	# 尺寸界线的超出方向：竖直标注的界线是水平的，不能沿尺寸线方向延伸
	var dv := _dim(doc, EntDim.make_linear(Vector2(0, 0), Vector2(0, 3000), Vector2(-800, 1500)))
	var overshoot := st.scaled(st.ext_line_extension)
	var ok_ext := false
	for s in _segs(dv):
		# 竖直标注的尺寸界线应自 (0,y) 水平引到 (-800-250, y)
		if absf(s.a.y - s.b.y) < 1e-6 and absf(s.a.x - s.b.x) > 900.0:
			ok_ext = true
	ok(ok_ext, "竖直标注的尺寸界线应为水平方向，并超出尺寸线 %.0fmm" % overshoot)
