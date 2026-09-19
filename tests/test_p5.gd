class_name P5Tests
extends TestSuite
## 建筑专用工具的测试：轴网、墙体、门窗洞口、房间面积、门窗表。


func run() -> void:
	suite = "轴网"
	_test_axis_letters()
	_test_span_parsing()
	_test_grid_build()

	suite = "墙体"
	_test_wall_geometry()
	_test_wall_openings()
	_test_wall_area()

	suite = "墙体并集"
	_test_wall_union()

	suite = "房间面积"
	_test_room_area_from_grid()
	_test_room_area_l_shape()

	suite = "门窗表"
	_test_schedule()


# ---------------------------------------------------------------------------
# 轴网
# ---------------------------------------------------------------------------

## GB/T 50001：纵向编号不采用 I、O、Z，以免与 1、0、2 混淆
func _test_axis_letters() -> void:
	var l := AxisGrid.axis_letters(6)
	ok(l.size() == 6, "应生成 6 个编号，实际 %d" % l.size())
	ok(l[0] == "A" and l[1] == "B" and l[2] == "C", "前三个应为 A B C")
	ok(l[3] == "D" and l[4] == "E" and l[5] == "F", "I 应被跳过，第四个是 D")
	# 一直取到 30 个，确认 O 与 Z 也被跳过
	var big := AxisGrid.axis_letters(30)
	ok(not big.has("I"), "编号不应出现 I")
	ok(not big.has("O"), "编号不应出现 O")
	ok(not big.has("Z"), "编号不应出现 Z")
	ok(big.size() == 23, "26 个字母去掉 I O Z 应剩 23 个，实际 %d" % big.size())
	# 横向编号是数字
	var n := AxisGrid.axis_numbers(4)
	ok(n.size() == 4 and n[0] == "1" and n[3] == "4", "横向编号应为 1 2 3 4")


func _test_span_parsing() -> void:
	var a := AxisGrid.parse_spans("3600 4200 3600")
	ok(a.size() == 3, "三段轴距")
	close(a[0], 3600.0, "第一段")
	close(a[2], 3600.0, "第三段")
	# 倍写
	var b := AxisGrid.parse_spans("3*3600 4200")
	ok(b.size() == 4, "3*3600 加一段 4200 应为 4 段，实际 %d" % b.size())
	close(b[0], 3600.0, "倍写展开")
	close(b[3], 4200.0, "倍写后的额外段")
	# 非法输入
	ok(AxisGrid.parse_spans("abc").is_empty(), "非法输入应返回空")
	ok(AxisGrid.parse_spans("3600 -200").is_empty(), "负数轴距应返回空")
	ok(AxisGrid.parse_spans("").is_empty(), "空输入应返回空")
	# 位置累加
	var pos := AxisGrid.positions_from_spans([3600.0, 4200.0])
	ok(pos.size() == 3, "两段轴距对应三条轴线")
	close(pos[0], 0.0, "首轴在 0")
	close(pos[1], 3600.0, "第二轴")
	close(pos[2], 7800.0, "第三轴")


func _test_grid_build() -> void:
	var doc := CadDocument.new()
	AxisGrid.build(doc, [0.0, 3600.0, 7800.0], [0.0, 3000.0, 6000.0],
		Vector2.ZERO, 900.0, 1200.0, true)
	# 3 + 3 条轴线，两端各一个轴线号 => 6*2 = 12 个轴线号
	var lines := 0
	var bubbles := 0
	var dims := 0
	for e in doc.entities:
		if e is EntLine:
			lines += 1
		elif e is EntSymbols.AxisBubble:
			bubbles += 1
		elif e is EntDim:
			dims += 1
	ok(lines >= 6, "应有 6 条轴线，实际 %d" % lines)
	ok(bubbles == 12, "3+3 条轴线两端各一个轴线号，应为 12 个，实际 %d" % bubbles)
	ok(dims > 0, "应生成尺寸标注")
	# 轴线应在「轴线」图层，且线型为单点长画线
	var l := doc.get_layer("轴线")
	ok(l != null, "应建立轴线图层")
	if l != null:
		ok(l.linetype == "CENTER", "轴线图层应用单点长画线，实际 %s" % l.linetype)
		close(l.lineweight, 0.25, "定位轴线线宽为 0.25mm")


# ---------------------------------------------------------------------------
# 墙体
# ---------------------------------------------------------------------------

func _test_wall_geometry() -> void:
	# 一段 6000 长、240 厚的墙，无洞口：应生成一个矩形（4 条线）
	var w := EntWall.make(PackedVector2Array([Vector2(0, 0), Vector2(6000, 0)]), 240.0)
	var cs := w.get_curves()
	ok(cs.size() == 4, "无洞口直墙应生成 4 条边，实际 %d" % cs.size())
	# 两条长边应在 y = ±120
	var ys := {}
	for c in cs:
		var s := c as GeoSeg
		if s.a.y == s.b.y:
			ys[snappedf(s.a.y, 0.01)] = true
	ok(ys.has(120.0) and ys.has(-120.0), "双线应在中心线两侧各 120mm")

	# 闭合矩形墙：四段各成一个矩形 => 16 条边
	var ring := EntWall.make(PackedVector2Array([
		Vector2(0, 0), Vector2(6000, 0), Vector2(6000, 4000), Vector2(0, 4000)]),
		240.0, true)
	ok(ring.get_curves().size() == 16, "闭合矩形墙应生成 16 条边，实际 %d" % ring.get_curves().size())


func _test_wall_openings() -> void:
	var w := EntWall.make(PackedVector2Array([Vector2(0, 0), Vector2(6000, 0)]), 240.0)
	ok(w.get_curves().size() == 4, "开洞前为 4 条边")
	# 在中间开一个 900 宽的洞
	ok(w.add_opening(3000.0, 900.0, "M0921", false), "洞口应能加入")
	# 两段墙各 4 条边 => 8 条
	ok(w.get_curves().size() == 8, "开洞后应分成两段共 8 条边，实际 %d" % w.get_curves().size())
	# 洞口两侧的垛口：两段墙的端边应落在 2550 与 3450
	var has_jamb := false
	for c in w.get_curves():
		var s := c as GeoSeg
		if absf(s.a.x - 2550.0) < 0.1 and absf(s.b.x - 2550.0) < 0.1:
			has_jamb = true
	ok(has_jamb, "洞口左侧应形成垛口端边")

	# 与已有洞口重叠应被拒绝
	ok(not w.add_opening(3200.0, 900.0, "M0921", false), "与已有洞口重叠应拒绝")
	# 超出墙端应被拒绝
	ok(not w.add_opening(100.0, 900.0, "M0921", false), "超出墙端应拒绝")
	ok(not w.add_opening(5900.0, 900.0, "M0921", false), "超出墙端应拒绝")
	# 合法位置
	ok(w.add_opening(5000.0, 1200.0, "C1215", true), "第二个洞口应能加入")

	# 洞口应能生成块引用（位置在洞口中心、方向沿墙）
	var inserts := w.opening_inserts()
	ok(inserts.size() == 2, "两个洞口应生成两个块引用，实际 %d" % inserts.size())
	if inserts.size() > 0:
		var ins := inserts[0] as EntInsert
		vclose(ins.position, Vector2(3000.0, 0.0), "块引用应落在洞口中心", 1e-3)
		close(ins.rotation, 0.0, "沿 X 方向的墙，门窗不应旋转", 1e-6)

	# 竖直墙上的洞口，块引用应旋转 90°
	var wv := EntWall.make(PackedVector2Array([Vector2(0, 0), Vector2(0, 6000)]), 240.0)
	wv.add_opening(3000.0, 900.0, "M0921", false)
	var insv := (wv.opening_inserts()[0]) as EntInsert
	close(insv.rotation, PI * 0.5, "竖直墙上的门窗应旋转 90°", 1e-6)
	vclose(insv.position, Vector2(0.0, 3000.0), "竖直墙上洞口的位置", 1e-3)

	# 移除洞口应恢复
	var w2 := EntWall.make(PackedVector2Array([Vector2(0, 0), Vector2(6000, 0)]), 240.0)
	w2.add_opening(3000.0, 900.0, "M0921", false)
	ok(w2.remove_opening_at(3000.0), "应能移除洞口")
	ok(w2.get_curves().size() == 4, "移除洞口后恢复 4 条边")


func _test_wall_area() -> void:
	var w := EntWall.make(PackedVector2Array([Vector2(0, 0), Vector2(6000, 0)]), 240.0)
	close(w.wall_area(), 6000.0 * 240.0, "无洞口墙体面积 = 长 × 厚", 1e-3)
	w.add_opening(3000.0, 900.0, "M0921", false)
	close(w.wall_area(), 6000.0 * 240.0 - 900.0 * 240.0, "开洞后应扣除洞口面积", 1e-3)


# ---------------------------------------------------------------------------
# 墙体并集
# ---------------------------------------------------------------------------

## 相邻墙体必须合并成一条外轮廓，否则接头处会露出内部线
func _test_wall_union() -> void:
	var a := PackedVector2Array([Vector2(0, 0), Vector2(1000, 0), Vector2(1000, 200), Vector2(0, 200)])
	var b := PackedVector2Array([Vector2(1000, 0), Vector2(2000, 0), Vector2(2000, 200), Vector2(1000, 200)])
	var res := WallUnion.union_all([a, b])
	ok(res.size() == 1, "首尾相接的两段墙应并成一个多边形，实际 %d" % res.size())
	if res.size() == 1:
		close(_poly_area(res[0]), 2000.0 * 200.0, "并集面积应等于两段之和", 1e-3)

	# 分离的两段不应被并成一块
	var c := PackedVector2Array([Vector2(5000, 0), Vector2(6000, 0), Vector2(6000, 200), Vector2(5000, 200)])
	var res2 := WallUnion.union_all([a, c])
	ok(res2.size() == 2, "分离的两段墙应保持两块，实际 %d" % res2.size())

	# L 形相接
	var d := PackedVector2Array([Vector2(0, 200), Vector2(200, 200), Vector2(200, 1200), Vector2(0, 1200)])
	var res3 := WallUnion.union_all([a, d])
	ok(res3.size() == 1, "L 形相接应并成一块，实际 %d" % res3.size())
	if res3.size() == 1:
		close(_poly_area(res3[0]), 1000.0 * 200.0 + 200.0 * 1000.0, "L 形并集面积", 1e-3)


func _poly_area(p: PackedVector2Array) -> float:
	var s := 0.0
	var n := p.size()
	for i in range(n):
		var m := p[i]
		var q := p[(i + 1) % n]
		s += m.x * q.y - q.x * m.y
	return absf(s) * 0.5


# ---------------------------------------------------------------------------
# 房间面积
# ---------------------------------------------------------------------------

## 由墙体围成 4 个房间，逐个校验净面积
func _test_room_area_from_grid() -> void:
	var doc := CadDocument.new()
	# 外墙环 7800×6000，纵向隔墙 x=3600，横向隔墙 y=3000
	var ring := EntWall.make(PackedVector2Array([
		Vector2(0, 0), Vector2(7800, 0), Vector2(7800, 6000), Vector2(0, 6000)]), 240.0, true)
	doc.add_entity(ring, false)
	var v := EntWall.make(PackedVector2Array([Vector2(3600, 0), Vector2(3600, 6000)]), 120.0)
	doc.add_entity(v, false)
	var h := EntWall.make(PackedVector2Array([Vector2(0, 3000), Vector2(7800, 3000)]), 120.0)
	doc.add_entity(h, false)

	var walls: Array = [ring, v, h]
	# 下-左：轴线 3600×3000，扣外墙半厚 120 与内墙半厚 60
	var r1 := RoomFinder.find_room(walls, Vector2(1800, 1500))
	var expect1 := (3600.0 - 120.0 - 60.0) / 1000.0 * (3000.0 - 120.0 - 60.0) / 1000.0
	close(_poly_area(r1) / 1000000.0, expect1, "下-左房间净面积", 0.02)
	ok(r1.size() == 4, "矩形房间应为 4 个顶点，实际 %d" % r1.size())

	# 上-右：轴线 4200×3000
	var r2 := RoomFinder.find_room(walls, Vector2(5700, 4500))
	var expect2 := (4200.0 - 120.0 - 60.0) / 1000.0 * (3000.0 - 120.0 - 60.0) / 1000.0
	close(_poly_area(r2) / 1000000.0, expect2, "上-右房间净面积", 0.02)

	# 四个房间净面积之和 = 建筑内部净面积 − 两道内隔墙的占地面积。
	# 注意不能直接拿"内部净面积"作期望：隔墙本身是占面积的实体。
	var total := 0.0
	for pt in [Vector2(1800, 1500), Vector2(1800, 4500), Vector2(5700, 1500), Vector2(5700, 4500)]:
		total += _poly_area(RoomFinder.find_room(walls, pt)) / 1000000.0
	var inner_w := 7800.0 - 240.0
	var inner_h := 6000.0 - 240.0
	var whole := inner_w / 1000.0 * inner_h / 1000.0
	var part_v_area := 120.0 / 1000.0 * inner_h / 1000.0
	var part_h_area := 120.0 / 1000.0 * inner_w / 1000.0
	# 两道隔墙相交处被重复扣了一次，扣回来
	var overlap := 0.120 * 0.120
	var expect := whole - part_v_area - part_h_area + overlap
	close(total, expect, "四个房间净面积之和 = 内部净面积 − 隔墙占地", 0.05)
	ok(total < whole, "房间面积之和应小于内部净面积（隔墙占面积）")

	# 点落在墙里应返回空
	ok(RoomFinder.find_room(walls, Vector2(0, 0)).size() == 0, "点在墙体上不应得到房间")
	# 点落在建筑外
	var outside := RoomFinder.find_room(walls, Vector2(-5000, -5000))
	ok(outside.size() == 0 or _poly_area(outside) > 100000000.0,
		"建筑外的点不应得到房间面积")


## L 形房间：面追踪应给出正确的凹多边形
func _test_room_area_l_shape() -> void:
	var doc := CadDocument.new()
	# 外轮廓为 L 形，闭合墙
	var l_shape := PackedVector2Array([
		Vector2(0, 0), Vector2(6000, 0), Vector2(6000, 3000),
		Vector2(3000, 3000), Vector2(3000, 6000), Vector2(0, 6000)])
	var ring := EntWall.make(l_shape, 240.0, true)
	doc.add_entity(ring, false)
	var r := RoomFinder.find_room([ring], Vector2(1500, 1500))
	ok(r.size() >= 6, "L 形房间应有至少 6 个顶点，实际 %d" % r.size())
	# 理论面积：外轮廓 6000×6000 减去右上角 3000×3000，再扣半墙厚的收缩
	var a := _poly_area(r) / 1000000.0
	ok(a > 20.0 and a < 30.0, "L 形房间净面积应在 20~30 m²，实际 %.2f" % a)


# ---------------------------------------------------------------------------
# 门窗表
# ---------------------------------------------------------------------------

func _test_schedule() -> void:
	var doc := CadDocument.new()
	GbBlocks.install(doc)
	var w := EntWall.make(PackedVector2Array([Vector2(0, 0), Vector2(20000, 0)]), 240.0)
	doc.add_entity(w, false)
	w.add_opening(2000.0, 900.0, "M0921", false)
	w.add_opening(4000.0, 900.0, "M0921", false)
	w.add_opening(8000.0, 1500.0, "C1515", true)
	var stats := CmdArch.ScheduleCmd.collect(doc)
	ok(stats.has("M0921"), "门窗表应统计到 M0921")
	ok(stats.has("C1515"), "门窗表应统计到 C1515")
	if stats.has("M0921"):
		ok(int((stats["M0921"] as Dictionary)["count"]) == 2, "M0921 应有 2 樘")
		ok(not bool((stats["M0921"] as Dictionary)["window"]), "M0921 应判为门")
	if stats.has("C1515"):
		ok(int((stats["C1515"] as Dictionary)["count"]) == 1, "C1515 应有 1 樘")
		ok(bool((stats["C1515"] as Dictionary)["window"]), "C1515 应判为窗")
		close(float((stats["C1515"] as Dictionary)["width"]), 1500.0, "C1515 洞口宽")

	# 编号到洞口宽度的换算
	close(CmdArch.OpeningCmd.width_from_code("M0921"), 900.0, "M0921 -> 900")
	close(CmdArch.OpeningCmd.width_from_code("C1515"), 1500.0, "C1515 -> 1500")
	close(CmdArch.OpeningCmd.width_from_code("C2115"), 2100.0, "C2115 -> 2100")
	close(CmdArch.OpeningCmd.width_from_code("bad"), 0.0, "非法编号应返回 0")
