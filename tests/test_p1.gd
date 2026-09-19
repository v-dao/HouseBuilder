class_name P1Tests
extends TestSuite
## P1 阶段的测试：空间索引、选择集、夹点变换、新增图元。


func run() -> void:
	suite = "四叉树空间索引"
	_test_quadtree()
	_test_quadtree_bounds()

	suite = "选择集"
	_test_window_vs_crossing()
	_test_pick_nearest()
	_test_selection_transforms()

	suite = "新增图元"
	_test_ellipse()
	_test_spline()
	_test_xline_and_point()
	_test_new_entity_roundtrip()

	suite = "拉伸语义"
	_test_stretch_semantics()

	suite = "命令注册表"
	_test_registry()


# ---------------------------------------------------------------------------
# 四叉树
# ---------------------------------------------------------------------------

func _test_quadtree() -> void:
	# 造 200 条散布的线段，验证索引查询结果与暴力扫描一致
	var doc := CadDocument.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i in range(200):
		var x := rng.randf_range(0.0, 10000.0)
		var y := rng.randf_range(0.0, 10000.0)
		doc.add_entity(EntLine.make(Vector2(x, y), Vector2(x + 500.0, y + 300.0)), false)
	var q := SpatialIndex.build(doc.entities, Rect2(0, 0, 10000, 10000))
	var st := q.stats()
	ok(int(st["items"]) == 200, "索引内图元总数应为 200，实际 %d" % int(st["items"]))
	ok(int(st["nodes"]) >= 1, "索引应至少有一个节点")

	# 与暴力扫描逐区域比对
	for k in range(12):
		var rx := rng.randf_range(0.0, 9000.0)
		var ry := rng.randf_range(0.0, 9000.0)
		var rect := Rect2(rx, ry, 2000.0, 2000.0)
		var brute: Array[CadEntity] = []
		for e in doc.entities:
			if e.get_bbox().intersects(rect):
				brute.append(e)
		var got := q.query_rect(rect)
		ok(got.size() == brute.size(),
			"区域查询结果数应与暴力扫描一致（索引 %d / 暴力 %d）" % [got.size(), brute.size()])
		# 索引结果必须是暴力结果的子集（不能多也不能少）
		for e in got:
			if not brute.has(e):
				ok(false, "索引返回了暴力扫描未命中的图元")
				break
	# 完全不重叠的区域应返回空
	ok(q.query_rect(Rect2(50000, 50000, 100, 100)).is_empty(), "区域外查询应为空")


func _test_quadtree_bounds() -> void:
	var doc := CadDocument.new()
	for i in range(50):
		doc.add_entity(EntLine.make(Vector2(float(i) * 100.0, 0), Vector2(float(i) * 100.0, 500.0)), false)
	var q := SpatialIndex.build(doc.entities, Rect2(0, 0, 5000, 5000))
	# 边界处的图元也必须能被查到（四叉树最容易在这里丢对象）
	var hit := q.query_rect(Rect2(-1, -1, 2, 2))
	ok(hit.size() == 1, "位于坐标原点的图元应能被查到，实际 %d" % hit.size())
	var last := q.query_rect(Rect2(4899, -1, 2, 2))
	ok(last.size() == 1, "位于边界末端的图元应能被查到，实际 %d" % last.size())


# ---------------------------------------------------------------------------
# 选择集
# ---------------------------------------------------------------------------

func _test_window_vs_crossing() -> void:
	var doc := CadDocument.new()
	# 完全在框内的线
	var inside := EntLine.make(Vector2(10, 10), Vector2(90, 90))
	# 一端在框内的线
	var partial := EntLine.make(Vector2(50, 50), Vector2(500, 500))
	# 完全在框外的线
	var outside := EntLine.make(Vector2(1000, 1000), Vector2(1100, 1100))
	doc.add_entity(inside, false)
	doc.add_entity(partial, false)
	doc.add_entity(outside, false)
	var q := SpatialIndex.build(doc.entities, Rect2(0, 0, 2000, 2000))
	var box := Rect2(0, 0, 100, 100)

	var win := CadSelection.window_select(doc, q, box)
	ok(win.size() == 1, "窗选只应选中完全落在框内的图元，实际 %d" % win.size())
	if win.size() == 1:
		ok(win[0] == inside, "窗选选中的应是完全在框内的那条线")

	var cross := CadSelection.crossing_select(doc, q, box)
	ok(cross.size() == 2, "交叉选应选中相交的两条线，实际 %d" % cross.size())

	# 栅栏选：一条穿过两条线的折线
	var fence := PackedVector2Array([Vector2(-50, 50), Vector2(600, 50)])
	var f := CadSelection.fence_select(doc, q, fence)
	ok(f.size() >= 1, "栅栏选应至少选中一条线，实际 %d" % f.size())


func _test_pick_nearest() -> void:
	var doc := CadDocument.new()
	var far := EntLine.make(Vector2(100, 0), Vector2(200, 0))
	var near := EntCircle.make(Vector2(0, 0), 10.0)
	doc.add_entity(far, false)
	doc.add_entity(near, false)
	var q := SpatialIndex.build(doc.entities, Rect2(-200, -200, 600, 600))
	# 点在圆附近，应拾取到圆而不是远处的线
	var e := CadSelection.pick(doc, q, Vector2(10.5, 0), 3.0)
	ok(e == near, "应拾取到最近的圆")
	# 容差外应拾取不到
	var e2 := CadSelection.pick(doc, q, Vector2(50, 50), 3.0)
	ok(e2 == null, "容差外不应拾取到任何图元")
	# 关闭的图层不可拾取
	var l := doc.get_layer("0")
	l.visible = false
	var e3 := CadSelection.pick(doc, q, Vector2(10.5, 0), 3.0)
	ok(e3 == null, "关闭图层上的图元不应被拾取")
	l.visible = true


func _test_selection_transforms() -> void:
	# 旋转：绕基点转 90°，点 (10,0) 应到 (0,10)
	var doc := CadDocument.new()
	var l := EntLine.make(Vector2(10, 0), Vector2(20, 0))
	doc.add_entity(l, false)
	var sel := CadSelection.new()
	sel.add(l)
	doc.begin_transaction("t")
	sel.rotate(doc, Vector2.ZERO, PI * 0.5)
	doc.commit_transaction()
	vclose(l.p0, Vector2(0, 10), "绕原点旋转 90° 后的起点", 1e-4)
	vclose(l.p1, Vector2(0, 20), "旋转后终点", 1e-4)

	# 缩放：绕基点 (10,0) 放大 2 倍，基点不动、远端翻倍
	var l2 := EntLine.make(Vector2(10, 0), Vector2(20, 0))
	var sel2 := CadSelection.new()
	sel2.add(l2)
	doc.begin_transaction("t")
	sel2.scale(doc, Vector2(10, 0), 2.0)
	doc.commit_transaction()
	vclose(l2.p0, Vector2(10, 0), "缩放基点保持不动", 1e-4)
	vclose(l2.p1, Vector2(30, 0), "缩放后远端距离翻倍", 1e-4)

	# 镜像：关于 Y 轴（过原点的竖直线）
	var l3 := EntLine.make(Vector2(10, 5), Vector2(20, 5))
	var sel3 := CadSelection.new()
	sel3.add(l3)
	doc.begin_transaction("t")
	sel3.mirror(doc, Vector2(0, 0), Vector2(0, 100))
	doc.commit_transaction()
	vclose(l3.p0, Vector2(-10, 5), "关于 Y 轴镜像后起点", 1e-4)
	vclose(l3.p1, Vector2(-20, 5), "关于 Y 轴镜像后终点", 1e-4)


# ---------------------------------------------------------------------------
# 新增图元
# ---------------------------------------------------------------------------

func _test_ellipse() -> void:
	var el := EntEllipse.make(Vector2.ZERO, 100.0, 50.0)
	ok(el.is_full(), "整椭圆判定")
	# a=100, b=50 的椭圆周长精确值约 484.4224（由完全椭圆积分算得）。
	# 实现用的是 Ramanujan 第二近似，该近似在此处误差约 1e-8，
	# 所以这里按 0.01% 相对精度断言，而不是用粗糙的 pi*(a+b) 作基准。
	close(el.curve().curve_length(), 484.4224, "椭圆周长（Ramanujan 近似）", 0.05)
	# 周长必须落在内接圆与外接圆周长之间，作为量级校验
	var pmin := TAU * 50.0
	var pmax := TAU * 100.0
	var plen := el.curve().curve_length()
	ok(plen > pmin and plen < pmax, "椭圆周长应在内外接圆之间（%.2f < %.2f < %.2f）" % [pmin, plen, pmax])
	var bb := el.get_bbox()
	vclose(bb.position, Vector2(-100, -50), "轴对齐椭圆包围盒左下", 1e-3)
	ok(absf(bb.size.x - 200.0) < 1e-3 and absf(bb.size.y - 100.0) < 1e-3, "轴对齐椭圆包围盒尺寸")
	# 细分点应落在椭圆上
	var c := el.curve()
	for p in c.tessellate(0.5):
		var v := p - el.center
		var q := (v.x / el.radius_a) * (v.x / el.radius_a) + (v.y / el.radius_b) * (v.y / el.radius_b)
		ok(absf(q - 1.0) < 2.0e-3, "细分点应满足椭圆方程，实际 %.6f" % q)
	# 旋转 90° 后包围盒的长短轴互换
	var el2 := EntEllipse.make(Vector2.ZERO, 100.0, 50.0, PI * 0.5)
	var bb2 := el2.get_bbox()
	ok(absf(bb2.size.x - 100.0) < 1e-3 and absf(bb2.size.y - 200.0) < 1e-3, "旋转 90° 后包围盒互换")
	# 变换
	var t := Transform2D(Vector2(2, 0), Vector2(0, 2), Vector2(1000, 0))
	el.transform_by(t)
	close(el.radius_a, 200.0, "椭圆缩放后长半轴")
	vclose(el.center, Vector2(1000, 0), "椭圆平移后中心")


func _test_spline() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(100, 100), Vector2(200, 0)])
	var sp := GeoSpline.make(pts)
	# Catmull-Rom 必须严格通过型值点
	vclose(sp.point_at(0.0), Vector2(0, 0), "样条通过第一个型值点", 1e-4)
	vclose(sp.point_at(1.0), Vector2(200, 0), "样条通过最后一个型值点", 1e-4)
	vclose(sp.point_at(0.5), Vector2(100, 100), "样条通过中间型值点", 1e-4)
	# 细分应足够接近曲线（误差不超过给定矢高）
	var sag := 0.5
	var tess := sp.tessellate(sag)
	ok(tess.size() >= 4, "样条细分点数应足够，实际 %d" % tess.size())
	var max_dev := 0.0
	for p in tess:
		var r := sp.closest_point(p)
		# 细分点本身就在曲线上，偏差应接近 0
		max_dev = maxf(max_dev, float(r["dist"]))
	ok(max_dev <= sag, "细分点的曲线上偏差应在矢高内，实际 %.6f" % max_dev)
	ok(sp.curve_length() > 200.0, "弯曲样条的弧长应大于端点直线距离")
	# 开口样条首尾与型值点一致
	vclose(sp.start_point(), pts[0], "样条起点", 1e-6)
	vclose(sp.end_point(), pts[2], "样条终点", 1e-6)
	# 闭合样条
	var spc := GeoSpline.make(pts, true)
	ok(spc.is_closed(), "闭合样条判定")


func _test_xline_and_point() -> void:
	var xl := EntXline.make(Vector2(0, 0), Vector2(1, 1))
	ok(not xl.ray, "默认为双向构造线")
	var c := xl.get_curves()[0] as GeoSeg
	# 构造线向两侧延伸，端点应关于给定点对称
	vclose(c.midpoint(), Vector2(0, 0), "构造线中点即给定点", 1e-3)
	ok(c.curve_length() >= EntXline.HALF_EXTENT * 2.0 - 1.0, "构造线长度接近两倍半长")
	var ry := EntXline.make(Vector2(0, 0), Vector2(1, 0), true)
	ok(ry.ray, "射线标记")
	vclose(ry.get_curves()[0].start_point(), Vector2(0, 0), "射线起点即给定点")

	var pt := EntPoint.make(Vector2(123.0, 456.0))
	close(pt.distance_to(Vector2(123.0, 460.0)), 4.0, "点到点的距离")
	# 点的包围盒必须非零，否则会被视口剔除逻辑误判
	ok(pt.get_bbox().size.x > 0.0 and pt.get_bbox().size.y > 0.0, "点的包围盒应非零")


func _test_new_entity_roundtrip() -> void:
	var src: Array[CadEntity] = [
		EntEllipse.make(Vector2(100, 200), 300.0, 120.0, 0.7, 0.3, 2.4),
		EntPoint.make(Vector2(-50, 25)),
		EntXline.make(Vector2(10, 10), Vector2(0.7071, 0.7071), true),
		EntSpline.make(PackedVector2Array([Vector2(0, 0), Vector2(50, 80), Vector2(120, 30)]), false),
	]
	for e: CadEntity in src:
		e.layer = "墙体"
		e.aci = 256
		var d := e.to_dict()
		var r := _rebuild(d)
		ok(r != null, "%s 应能从字典重建" % e.type_name())
		if r == null:
			continue
		ok(r.layer == e.layer, "%s 图层往返" % e.type_name())
		ok(r.aci == e.aci, "%s 颜色索引往返" % e.type_name())
		var a := e.get_bbox()
		var b := r.get_bbox()
		ok(a.position.distance_to(b.position) <= 1e-3 and a.size.distance_to(b.size) <= 1e-3,
			"%s 包围盒往返 (%.4f,%.4f)+/-(%.4f,%.4f) vs (%.4f,%.4f)+/-(%.4f,%.4f)" % [
				e.type_name(), a.position.x, a.position.y, a.size.x, a.size.y,
				b.position.x, b.position.y, b.size.x, b.size.y])
	# 射线标记必须保留
	var xl := EntXline.make(Vector2(0, 0), Vector2(1, 0), true)
	var xl2 := EntXline.from_dict(xl.to_dict())
	ok(xl2.ray, "射线的 ray 标记应往返保留")
	# 样条型值点必须精确保留
	var sp := EntSpline.make(PackedVector2Array([Vector2(1, 2), Vector2(3, 4)]), true)
	var sp2 := EntSpline.from_dict(sp.to_dict())
	ok(sp2.fit_points().size() == 2, "样条型值点数量往返")
	ok(sp2.is_closed(), "样条闭合标记往返")
	vclose(sp2.fit_points()[1], Vector2(3, 4), "样条型值点坐标往返", 1e-6)


func _rebuild(d: Dictionary) -> CadEntity:
	match int(d.get("type", -1)):
		CadEntity.Type.ELLIPSE:
			return EntEllipse.from_dict(d)
		CadEntity.Type.POINT:
			return EntPoint.from_dict(d)
		CadEntity.Type.XLINE, CadEntity.Type.RAY:
			return EntXline.from_dict(d)
		CadEntity.Type.SPLINE:
			return EntSpline.from_dict(d)
	return null


# ---------------------------------------------------------------------------
# 拉伸语义
# ---------------------------------------------------------------------------

## STRETCH 与 MOVE 的本质区别：只移动交叉窗口内的定义点。
func _test_stretch_semantics() -> void:
	var doc := CadDocument.new()
	var l := EntLine.make(Vector2(0, 0), Vector2(1000, 0))
	doc.add_entity(l, false)
	# 直线的定义点只有两端，不含中点
	ok(l.get_stretch_points().size() == 2, "直线的可拉伸定义点应为 2 个（不含中点夹点）")
	var win := Rect2(-10, -10, 120, 20)  # 只框住起点
	var pts := l.get_stretch_points()
	var inside: Array[int] = []
	for i in range(pts.size()):
		if win.has_point(pts[i]):
			inside.append(i)
	ok(inside.size() == 1, "交叉窗口只应框住一个定义点")
	# 移动框内的那个点 -> 线被拉伸
	l.move_stretch_point(inside[0], pts[inside[0]] + Vector2(-200, 300))
	vclose(l.p0, Vector2(-200, 300), "起点被拉伸")
	vclose(l.p1, Vector2(1000, 0), "终点保持不动（这是拉伸而非移动）")

	# 多段线的定义点是各顶点
	var pl := EntPolyline.make(PackedVector2Array([
		Vector2(0, 0), Vector2(500, 0), Vector2(500, 500)]))
	ok(pl.get_stretch_points().size() == 3, "多段线定义点应为 3 个顶点")
	pl.move_stretch_point(2, Vector2(800, 900))
	vclose(pl.poly.points[2], Vector2(800, 900), "多段线顶点被拉伸")
	vclose(pl.poly.points[0], Vector2(0, 0), "多段线其他顶点不受影响")


# ---------------------------------------------------------------------------
# 命令注册表
# ---------------------------------------------------------------------------

func _test_registry() -> void:
	# 别名必须唯一，否则会出现命令歧义
	var seen := {}
	for d in CommandRegistry.DEFS:
		var name := String(d[0])
		var keys := [name.to_lower()]
		for a in (d[1] as Array):
			keys.append(String(a).to_lower())
		for k in keys:
			ok(not seen.has(k), "命令名/别名 %s 重复（已被 %s 占用）" % [k, seen.get(k, "")])
			seen[k] = name
	# 每个注册的命令都要能创建出实例
	for d in CommandRegistry.DEFS:
		var name := String(d[0])
		if name in ["ZOOM", "UNDO", "REDO", "LAYER", "LWDISPLAY"]:
			continue  # 这几种由界面直接处理，不走命令工厂
		var cmd := CommandRegistry.create(name)
		ok(cmd != null, "%s 应能从注册表创建" % name)
		if cmd != null:
			ok(cmd.cmd_name() == name, "%s 的命令名应自洽，实际 %s" % [name, cmd.cmd_name()])
	# 别名解析
	ok(CommandRegistry.normalize("l") == "LINE", "别名 l -> LINE")
	ok(CommandRegistry.normalize("TR") == "TRIM", "别名 tr -> TRIM")
	ok(CommandRegistry.normalize("偏移") == "OFFSET", "中文别名 偏移 -> OFFSET")
	ok(CommandRegistry.normalize("圆角") == "FILLET", "中文别名 圆角 -> FILLET")
	ok(CommandRegistry.normalize("打酱油") == "", "未知命令应返回空")
	ok(CommandRegistry.is_command("CO"), "is_command 识别别名")
	ok(not CommandRegistry.is_command("XYZ"), "is_command 拒绝未知命令")
	# 前缀补全
	var c := CommandRegistry.complete("ci")
	ok(c.size() >= 1, "前缀 ci 应有补全候选")
	# 分类应覆盖全部命令
	var total := 0
	for cat in CommandRegistry.by_category().keys():
		total += (CommandRegistry.by_category()[cat] as Array).size()
	ok(total == CommandRegistry.DEFS.size(), "分类遍历应覆盖全部命令")
