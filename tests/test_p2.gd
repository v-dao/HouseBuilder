class_name P2Tests
extends TestSuite
## 捕捉引擎的测试。
##
## 捕捉是"画得准"的前提，但它的行为高度依赖优先级裁决与容差，
## 肉眼很难判断对错，必须用精确断言钉死。


func run() -> void:
	suite = "捕捉：对象捕捉"
	_test_endpoint_and_midpoint()
	_test_center_and_quadrant()
	_test_intersection()
	_test_perpendicular_and_tangent()
	_test_priority()
	_test_aperture_and_switches()

	suite = "捕捉：正交与极轴"
	_test_ortho()
	_test_polar()
	_test_grid()

	suite = "捕捉：类型开关"
	_test_mask()

	suite = "捕捉：对象捕捉追踪"
	_test_track_acquire()
	_test_track_axis()
	_test_track_cross()
	_test_track_priority()
	_test_track_hover()
	_test_track_switches()


## 造一个测试场景：一条水平线 (0,0)-(1000,0)，一个圆（圆心 (2000,0) 半径 500），
## 一条与水平线交叉的竖直线 (500,-500)-(500,500)
func _scene() -> Array:
	var doc := CadDocument.new()
	var line := EntLine.make(Vector2(0, 0), Vector2(1000, 0))
	var circ := EntCircle.make(Vector2(2000, 0), 500.0)
	var vert := EntLine.make(Vector2(500, -500), Vector2(500, 500))
	doc.add_entity(line, false)
	doc.add_entity(circ, false)
	doc.add_entity(vert, false)
	var q := SpatialIndex.build(doc.entities, Rect2(-1000, -1000, 5000, 3000))
	var view := ViewTransform.new()
	view.zoom = 1.0
	view.center = Vector2(1000, 0)
	view.set_view_size(Vector2(1600, 900))
	return [doc, q, view]


func _snap_at(view: ViewTransform, doc: CadDocument, q: SpatialIndex, p: Vector2, from = null) -> SnapEngine.Result:
	var eng := SnapEngine.new()
	# 靶框放大到 20 像素，便于在模型坐标里用较小的偏移量测试
	eng.aperture_px = 20.0
	return eng.resolve(doc, q, view, p, from)


# ---------------------------------------------------------------------------
# 对象捕捉
# ---------------------------------------------------------------------------

func _test_endpoint_and_midpoint() -> void:
	var sc := _scene()
	var doc: CadDocument = sc[0]
	var q: SpatialIndex = sc[1]
	var view: ViewTransform = sc[2]

	# 光标略偏离线端点 (0,0)，应吸附到精确端点
	var r := _snap_at(view, doc, q, Vector2(3, -2))
	ok(r.hit, "端点附近应命中捕捉")
	ok(r.type == SnapType.ENDPOINT, "应识别为端点，实际 %s" % SnapType.name_of(r.type))
	vclose(r.point, Vector2(0, 0), "端点应精确吸附到 (0,0)", 1e-6)

	# (500,0) 同时是水平线的中点、竖直线的中点、以及两者的交点。
	# 按 AutoCAD 的捕捉优先级（端点 > 中点 > 圆心 > 象限点 > 交点），
	# 中点胜出。这里刻意把这个顺序钉死，避免以后误改。
	var rm := _snap_at(view, doc, q, Vector2(502, 3))
	ok(rm.hit, "重合特征点附近应命中")
	ok(rm.type == SnapType.MIDPOINT, "中点与交点重合时应按 AutoCAD 顺序取中点，实际 %s" % SnapType.name_of(rm.type))
	vclose(rm.point, Vector2(500, 0), "重合点坐标", 1e-6)

	# 远离交点的中点：取水平线中点在竖直线上偏移后仍应识别为交点，
	# 因此这里改用只有一条线的场景测中点
	var doc2 := CadDocument.new()
	var l2 := EntLine.make(Vector2(0, 0), Vector2(1000, 0))
	doc2.add_entity(l2, false)
	var q2 := SpatialIndex.build(doc2.entities, Rect2(-500, -500, 2000, 1000))
	var r2 := _snap_at(view, doc2, q2, Vector2(498, 4))
	ok(r2.type == SnapType.MIDPOINT, "孤立线的中点应识别为中点，实际 %s" % SnapType.name_of(r2.type))
	vclose(r2.point, Vector2(500, 0), "中点坐标", 1e-6)


func _test_center_and_quadrant() -> void:
	var sc := _scene()
	var doc: CadDocument = sc[0]
	var q: SpatialIndex = sc[1]
	var view: ViewTransform = sc[2]
	# 圆心 (2000,0)
	var r := _snap_at(view, doc, q, Vector2(2004, 3))
	ok(r.hit, "圆心附近应命中")
	vclose(r.point, Vector2(2000, 0), "圆心坐标", 1e-4)
	# 象限点 (2500,0)：(2000+500, 0)
	var rq := _snap_at(view, doc, q, Vector2(2496, 4))
	ok(rq.hit, "象限点附近应命中")
	ok(rq.type == SnapType.QUADRANT or rq.type == SnapType.ENDPOINT or rq.type == SnapType.MIDPOINT,
		"象限点应被识别，实际 %s" % SnapType.name_of(rq.type))
	vclose(rq.point, Vector2(2500, 0), "象限点坐标", 1e-4)
	# 圆上任意位置应能命中最远点
	var rn := _snap_at(view, doc, q, Vector2(2000 + 500.0 * cos(0.7), 500.0 * sin(0.7) + 2.0))
	ok(rn.hit, "圆上任意点应能命中最近点")
	ok(absf(rn.point.distance_to(Vector2(2000, 0)) - 500.0) < 1e-3, "最近点应落在圆周上")


func _test_intersection() -> void:
	var sc := _scene()
	var doc: CadDocument = sc[0]
	var q: SpatialIndex = sc[1]
	var view: ViewTransform = sc[2]
	# 加一条斜线 (0,300)-(600,-100)，它与水平线 y=0 交于 (450,0)，
	# 而斜线自身的中点是 (300,100)，两者不重合，
	# 这样才能干净地验证"交点"捕捉本身是否生效。
	var diag := EntLine.make(Vector2(0, 300), Vector2(600, -100))
	doc.add_entity(diag, false)
	var q2 := SpatialIndex.build(doc.entities, Rect2(-1000, -1000, 5000, 3000))
	var r := _snap_at(view, doc, q2, Vector2(452, 3))
	ok(r.hit, "斜线与水平线交点附近应命中")
	ok(r.type == SnapType.INTERSECTION, "应识别为交点，实际 %s" % SnapType.name_of(r.type))
	vclose(r.point, Vector2(450, 0), "斜线交点坐标", 1e-4)


func _test_perpendicular_and_tangent() -> void:
	var sc := _scene()
	var doc: CadDocument = sc[0]
	var q: SpatialIndex = sc[1]
	var view: ViewTransform = sc[2]
	# 基点在 (200, 400)，水平线 y=0 上的垂足是 (200, 0)
	var r := _snap_at(view, doc, q, Vector2(203, 5), Vector2(200, 400))
	ok(r.hit, "垂足附近应命中")
	ok(r.type == SnapType.PERPENDICULAR, "应识别为垂足，实际 %s" % SnapType.name_of(r.type))
	vclose(r.point, Vector2(200, 0), "垂足坐标", 1e-4)

	# 切点：自 (2000, 2000) 向圆心 (2000,0) 半径 500 的圆作切线
	var base := Vector2(2000, 2000)
	var tan_pts := SnapEngine.new()._tangent_points(GeoArc.make_circle(Vector2(2000, 0), 500.0), base)
	ok(tan_pts.size() == 2, "圆外一点应有两条切线，实际 %d" % tan_pts.size())
	for tp in tan_pts:
		# 切线性质：切点到圆心连线 与 切点到基点连线 垂直。
		# 两个向量长度约 500 与 1936，点积的绝对量级约 1e6，
		# 所以必须比较归一化后的方向余弦，不能直接卡点积的绝对值。
		var rad := tp - Vector2(2000, 0)
		var tanv := base - tp
		var cosang := absf(rad.normalized().dot(tanv.normalized()))
		ok(cosang < 1.0e-5, "切点处半径应与切线垂直，方向余弦 = %s" % str(cosang))
		close(tp.distance_to(Vector2(2000, 0)), 500.0, "切点应在圆上", 1e-3)

	# 圆内一点没有切线
	var inside := SnapEngine.new()._tangent_points(GeoArc.make_circle(Vector2(2000, 0), 500.0), Vector2(2100, 0))
	ok(inside.is_empty(), "圆内一点不应有切线")


## 优先级是捕捉最容易出错的地方：多种捕捉同时命中时选错，用户会觉得"不听话"
func _test_priority() -> void:
	var doc := CadDocument.new()
	# 一条短线，光标同时靠近端点、中点、以及最近点
	var l := EntLine.make(Vector2(0, 0), Vector2(100, 0))
	doc.add_entity(l, false)
	var q := SpatialIndex.build(doc.entities, Rect2(-100, -100, 300, 200))
	var view := ViewTransform.new()
	view.zoom = 1.0
	view.set_view_size(Vector2(1600, 900))

	# 光标在端点附近且也在最近点范围内 -> 端点优先
	var r := _snap_at(view, doc, q, Vector2(2, 1))
	ok(r.type == SnapType.ENDPOINT, "端点应优先于最近点，实际 %s" % SnapType.name_of(r.type))

	# 关闭端点捕捉后，应降级为最近点
	var eng := SnapEngine.new()
	eng.aperture_px = 20.0
	eng.set_type_enabled(SnapType.ENDPOINT, false)
	var r2 := eng.resolve(doc, q, view, Vector2(2, 1), null)
	ok(r2.hit, "关闭端点后仍应命中")
	ok(r2.type == SnapType.NEAREST, "关闭端点后应降级为最近点，实际 %s" % SnapType.name_of(r2.type))

	# 全部对象捕捉关闭后不应命中
	var eng2 := SnapEngine.new()
	eng2.aperture_px = 20.0
	eng2.osnap_enabled = false
	var r3 := eng2.resolve(doc, q, view, Vector2(2, 1), null)
	ok(not r3.hit, "关闭对象捕捉后不应命中")
	vclose(r3.point, Vector2(2, 1), "无捕捉时应返回原始光标位置", 1e-6)


func _test_aperture_and_switches() -> void:
	var sc := _scene()
	var doc: CadDocument = sc[0]
	var q: SpatialIndex = sc[1]
	var view: ViewTransform = sc[2]
	# 远离所有几何的位置不应命中
	var r := _snap_at(view, doc, q, Vector2(5000, 5000))
	ok(not r.hit, "远离几何时不应命中捕捉")
	vclose(r.point, Vector2(5000, 5000), "未命中时返回原位置", 1e-6)
	# 隐藏图层上的图元不应参与捕捉
	var l := doc.get_layer("0")
	l.visible = false
	var q2 := SpatialIndex.build(doc.entities, Rect2(-1000, -1000, 5000, 3000))
	var r2 := _snap_at(view, doc, q2, Vector2(3, -2))
	ok(not r2.hit, "隐藏图层上的图元不应参与捕捉")
	l.visible = true


# ---------------------------------------------------------------------------
# 正交与极轴
# ---------------------------------------------------------------------------

func _test_ortho() -> void:
	var doc := CadDocument.new()
	var q := SpatialIndex.build(doc.entities, Rect2(-1000, -1000, 2000, 2000))
	var view := ViewTransform.new()
	view.zoom = 1.0
	view.set_view_size(Vector2(1600, 900))
	var eng := SnapEngine.new()
	eng.osnap_enabled = false
	eng.ortho = true

	# 水平分量大 -> 投影到水平
	var r := eng.resolve(doc, q, view, Vector2(1000, 200), Vector2(0, 0))
	ok(r.hit, "正交应产生约束结果")
	vclose(r.point, Vector2(1000, 0), "水平分量大时应投影到水平轴", 1e-6)
	# 垂直分量大 -> 投影到垂直
	var r2 := eng.resolve(doc, q, view, Vector2(100, 800), Vector2(0, 0))
	vclose(r2.point, Vector2(0, 800), "垂直分量大时应投影到竖直轴", 1e-6)
	# 无基点时正交不生效
	var r3 := eng.resolve(doc, q, view, Vector2(100, 800), null)
	ok(not r3.hit, "无基点时正交不应生效")


func _test_polar() -> void:
	var doc := CadDocument.new()
	var q := SpatialIndex.build(doc.entities, Rect2(-1000, -1000, 2000, 2000))
	var view := ViewTransform.new()
	view.zoom = 1.0
	view.set_view_size(Vector2(1600, 900))
	var eng := SnapEngine.new()
	eng.osnap_enabled = false
	eng.ortho = false
	eng.polar_enabled = true
	eng.polar_step_deg = 15.0
	var base := Vector2(0, 0)
	# 方向 47° 应吸附到 45°，且保持距离不变
	var cursor := base + Vector2(cos(deg_to_rad(47.0)), sin(deg_to_rad(47.0))) * 1000.0
	var r := eng.resolve(doc, q, view, cursor, base)
	ok(r.hit, "极轴应产生约束结果")
	ok(r.type == SnapType.POLAR, "应标记为极轴")
	close(r.point.distance_to(base), 1000.0, "极轴不应改变距离", 1e-3)
	var ang := rad_to_deg((r.point - base).angle())
	close(ang, 45.0, "47° 应吸附到 45°", 1e-4)
	# 30° 步长下 47° 应吸附到 60°
	eng.polar_step_deg = 30.0
	var r2 := eng.resolve(doc, q, view, cursor, base)
	close(rad_to_deg((r2.point - base).angle()), 60.0, "30° 步长下 47° 应吸附到 60°", 1e-4)


func _test_grid() -> void:
	var doc := CadDocument.new()
	var q := SpatialIndex.build(doc.entities, Rect2(-1000, -1000, 2000, 2000))
	var view := ViewTransform.new()
	view.zoom = 1.0
	view.set_view_size(Vector2(1600, 900))
	var eng := SnapEngine.new()
	eng.osnap_enabled = false
	eng.grid_snap = true
	eng.grid_step = 100.0
	var r := eng.resolve(doc, q, view, Vector2(148, -37), null)
	ok(r.hit, "栅格捕捉应命中")
	vclose(r.point, Vector2(100, 0), "148,-37 应吸附到 100,0", 1e-6)
	var r2 := eng.resolve(doc, q, view, Vector2(151, 149), null)
	vclose(r2.point, Vector2(200, 100), "151,149 应吸附到 200,100", 1e-6)


# ---------------------------------------------------------------------------
# 类型开关
# ---------------------------------------------------------------------------

func _test_mask() -> void:
	var eng := SnapEngine.new()
	ok(eng.is_type_enabled(SnapType.ENDPOINT), "端点默认启用")
	ok(eng.is_type_enabled(SnapType.INTERSECTION), "交点默认启用")
	eng.set_type_enabled(SnapType.ENDPOINT, false)
	ok(not eng.is_type_enabled(SnapType.ENDPOINT), "关闭端点后应不再启用")
	eng.set_type_enabled(SnapType.ENDPOINT, true)
	ok(eng.is_type_enabled(SnapType.ENDPOINT), "重新开启端点")
	# 开关不应影响其他类型
	ok(eng.is_type_enabled(SnapType.MIDPOINT), "开关某一类型不应影响其他类型")
	# 每种捕捉类型都要有中文名，界面上要显示
	for t in [SnapType.ENDPOINT, SnapType.MIDPOINT, SnapType.CENTER, SnapType.QUADRANT,
			SnapType.INTERSECTION, SnapType.PERPENDICULAR, SnapType.TANGENT,
			SnapType.NODE, SnapType.INSERTION, SnapType.NEAREST, SnapType.POLAR, SnapType.GRID]:
		ok(SnapType.name_of(t) != "未知", "捕捉类型 %d 应有中文名" % t)


# ---------------------------------------------------------------------------
# 对象捕捉追踪
# ---------------------------------------------------------------------------

func _empty_scene() -> Array:
	var doc := CadDocument.new()
	var q := SpatialIndex.build(doc.entities, Rect2(-1000, -1000, 4000, 4000))
	var view := ViewTransform.new()
	view.zoom = 1.0
	view.set_view_size(Vector2(1600, 900))
	return [doc, q, view]


func _test_track_acquire() -> void:
	var eng := SnapEngine.new()
	ok(eng.track_points.is_empty(), "初始无追踪基准")
	ok(eng.acquire(Vector2(100, 200)), "应能获取第一个基准")
	ok(not eng.acquire(Vector2(100, 200)), "同一位置不应重复获取")
	ok(not eng.acquire(Vector2(100.0005, 200.0005)), "容差内的近似点也不应重复")
	ok(eng.track_points.size() == 1, "去重后只应有一个基准")
	ok(eng.acquire(Vector2(500, 600)), "不同位置应能获取")
	ok(eng.track_points.size() == 2, "应有两个基准")
	# 超出上限时丢弃最早的
	for i in range(10):
		eng.acquire(Vector2(1000 + i * 100, 1000))
	ok(eng.track_points.size() == SnapEngine.MAX_TRACK_POINTS,
		"基准数应被限制在 %d 以内，实际 %d" % [SnapEngine.MAX_TRACK_POINTS, eng.track_points.size()])
	eng.clear_tracking()
	ok(eng.track_points.is_empty(), "清空后不应有基准")


## 单轴对齐：光标靠近基准的竖直轴时，x 被吸附，y 保持光标值
func _test_track_axis() -> void:
	var sc := _empty_scene()
	var doc: CadDocument = sc[0]
	var q: SpatialIndex = sc[1]
	var view: ViewTransform = sc[2]
	var eng := SnapEngine.new()
	eng.aperture_px = 20.0
	eng.acquire(Vector2(1000, 2000))
	# 光标在竖直轴附近（x 差 5，在 20 像素靶框内），y 远离水平轴
	var r := eng.resolve(doc, q, view, Vector2(1005, 3000), null)
	ok(r.hit, "靠近追踪轴应命中")
	ok(r.type == SnapType.TRACK, "应为追踪类型，实际 %s" % SnapType.name_of(r.type))
	close(r.point.x, 1000.0, "竖直轴应固定 x", 1e-6)
	close(r.point.y, 3000.0, "未命中的方向应保持光标值", 1e-6)
	ok(not r.is_track_cross, "只命中一条轴时不应判为交点")

	# 靠近水平轴（y 差 4）
	var r2 := eng.resolve(doc, q, view, Vector2(3000, 2004), null)
	ok(r2.hit, "靠近水平轴应命中")
	close(r2.point.y, 2000.0, "水平轴应固定 y", 1e-6)
	close(r2.point.x, 3000.0, "未命中的方向应保持光标值", 1e-6)

	# 远离两条轴则不命中
	var r3 := eng.resolve(doc, q, view, Vector2(3000, 3000), null)
	ok(not r3.hit, "远离追踪轴不应命中")


## 双轴交点：一横一竖同时命中时取交点
func _test_track_cross() -> void:
	var sc := _empty_scene()
	var doc: CadDocument = sc[0]
	var q: SpatialIndex = sc[1]
	var view: ViewTransform = sc[2]
	var eng := SnapEngine.new()
	eng.aperture_px = 20.0
	eng.acquire(Vector2(1000, 2000))   # 提供竖直轴 x=1000 与水平轴 y=2000
	eng.acquire(Vector2(3000, 4000))   # 提供竖直轴 x=3000 与水平轴 y=4000
	# 光标靠近 x=1000 的竖直轴与 y=4000 的水平轴 —— 两条轴来自不同基准
	var r := eng.resolve(doc, q, view, Vector2(1004, 3997), null)
	ok(r.hit, "应命中两条追踪轴的交叉区")
	ok(r.is_track_cross, "应判为追踪交点")
	close(r.point.x, 1000.0, "交点 x 取自竖直轴的基准", 1e-6)
	close(r.point.y, 4000.0, "交点 y 取自水平轴的基准", 1e-6)
	ok(r.track_axes.size() == 2, "应记录两条用到的轴，实际 %d" % r.track_axes.size())


## 对象捕捉优先于追踪：光标同时落在几何捕捉点与追踪轴上时取几何点
func _test_track_priority() -> void:
	var sc := _scene()
	var doc: CadDocument = sc[0]
	var q: SpatialIndex = sc[1]
	var view: ViewTransform = sc[2]
	var eng := SnapEngine.new()
	eng.aperture_px = 20.0
	# 基准点放在水平线端点 (0,0) 的正上方，使 (0,0) 同时是追踪轴交点与端点
	eng.acquire(Vector2(0, 500))
	eng.acquire(Vector2(500, 0))
	var r := eng.resolve(doc, q, view, Vector2(2, -3), null)
	ok(r.hit, "应命中")
	ok(r.type != SnapType.TRACK,
		"几何捕捉应优先于追踪，实际 %s" % SnapType.name_of(r.type))
	ok(r.type == SnapType.ENDPOINT, "应命中端点，实际 %s" % SnapType.name_of(r.type))


## 悬停获取：停在同一捕捉点上超过设定时长才记为基准
func _test_track_hover() -> void:
	var eng := SnapEngine.new()
	eng.acquire_linger_ms = 300
	var hit := SnapEngine.Result.new()
	hit.hit = true
	hit.point = Vector2(1000, 1000)
	hit.type = SnapType.ENDPOINT

	# 第一次出现：只记录，不获取
	ok(not eng.update_hover(hit, 0), "首次悬停不应立即获取")
	ok(eng.track_points.is_empty(), "此时不应有基准")
	# 200ms 后仍在同一位置：仍未到时
	ok(not eng.update_hover(hit, 200), "未到悬停时长不应获取")
	ok(eng.track_points.is_empty(), "此时仍不应有基准")
	# 400ms：到时，获取
	ok(eng.update_hover(hit, 400), "超过悬停时长应获取基准")
	ok(eng.track_points.size() == 1, "应有一个基准")

	# 位置变化会重新计时
	hit.point = Vector2(2000, 2000)
	ok(not eng.update_hover(hit, 500), "位置变化后应重新计时")
	ok(not eng.update_hover(hit, 700), "重新计时未到时不应获取")
	ok(eng.update_hover(hit, 900), "重新计时到时应获取")

	# 追踪结果本身不再作为新基准（否则会自我累积）
	var tr := SnapEngine.Result.new()
	tr.hit = true
	tr.point = Vector2(3000, 3000)
	tr.type = SnapType.TRACK
	ok(not eng.update_hover(tr, 2000), "追踪结果不应再被获取为基准")
	ok(not eng.update_hover(tr, 3000), "追踪结果不应再被获取为基准（到时后）")

	# 未命中的结果不参与
	var miss := SnapEngine.Result.new()
	ok(not eng.update_hover(miss, 4000), "未命中不应参与悬停获取")
	ok(not eng.update_hover(null, 4000), "空结果不应崩溃")


func _test_track_switches() -> void:
	var sc := _empty_scene()
	var doc: CadDocument = sc[0]
	var q: SpatialIndex = sc[1]
	var view: ViewTransform = sc[2]
	var eng := SnapEngine.new()
	eng.aperture_px = 20.0
	eng.acquire(Vector2(1000, 1000))
	# 关闭追踪后不生效
	eng.tracking_enabled = false
	ok(not eng.resolve(doc, q, view, Vector2(1003, 3000), null).hit, "关闭追踪后不应命中")
	# update_hover 在关闭时也不获取
	var hit := SnapEngine.Result.new()
	hit.hit = true
	hit.point = Vector2(7777, 7777)
	hit.type = SnapType.ENDPOINT
	ok(not eng.update_hover(hit, 0), "关闭追踪时不应获取")
	ok(not eng.update_hover(hit, 99999), "关闭追踪时不应获取（到时后）")
	# 重新开启后恢复
	eng.tracking_enabled = true
	ok(eng.resolve(doc, q, view, Vector2(1003, 3000), null).hit, "重新开启后应命中")
