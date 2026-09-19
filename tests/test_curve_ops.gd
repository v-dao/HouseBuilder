class_name CurveOpsTests
extends TestSuite
## 曲线运算内核的测试。
##
## 偏移方向约定（正值 = 行进方向左侧）与圆角切线长是最容易弄错的地方，
## 这里把它们全部钉死，后续所有编辑命令的符号都依赖这些约定。


func run() -> void:
	suite = "曲线运算：偏移"
	_test_offset_direction()
	_test_offset_poly_open()
	_test_offset_poly_closed()
	_test_offset_preserves_bulge()

	suite = "曲线运算：分割与裁剪"
	_test_split_poly()
	_test_slice_and_remove()

	suite = "曲线运算：圆角与倒角"
	_test_fillet()
	_test_fillet_sharp_angle()
	_test_chamfer()

	suite = "曲线运算：延伸定位与连接"
	_test_crossings_sorted()
	_test_try_join()

	suite = "曲线运算：求交"
	_test_intersect_entities()


# ---------------------------------------------------------------------------
# 偏移
# ---------------------------------------------------------------------------

## 偏移方向约定：正值 = 沿行进方向的左侧。这个约定必须钉死，
## 因为所有偏移命令的符号都依赖它。
func _test_offset_direction() -> void:
	# 水平线段方向 +X，左侧即 +Y
	var s := GeoSeg.make(Vector2(0, 0), Vector2(10, 0))
	var o := CurveOps.offset_curve(s, 5.0) as GeoSeg
	vclose(o.start_point(), Vector2(0, 5), "线段向左偏移 +5 -> y=+5", 1e-9)
	vclose(o.end_point(), Vector2(10, 5), "线段偏移后终点", 1e-9)
	var o2 := CurveOps.offset_curve(s, -3.0) as GeoSeg
	vclose(o2.start_point(), Vector2(0, -3), "负值向右侧偏移", 1e-9)

	# 逆时针圆的左侧指向圆心 -> 半径减小
	var ccw := GeoArc.make_circle(Vector2.ZERO, 10.0)
	var oc := CurveOps.offset_curve(ccw, 4.0) as GeoArc
	close(oc.radius, 6.0, "逆时针圆左偏 -> 半径 10-4=6")
	# 顺时针圆的左侧背离圆心 -> 半径增大
	var cw := GeoArc.make(Vector2.ZERO, 10.0, 0.0, TAU, false)
	var oc2 := CurveOps.offset_curve(cw, 4.0) as GeoArc
	close(oc2.radius, 14.0, "顺时针圆左偏 -> 半径 10+4=14")
	# 半径被吃穿应返回 null
	ok(CurveOps.offset_curve(ccw, 20.0) == null, "偏移量超过半径应返回 null")


func _test_offset_poly_open() -> void:
	# L 形开口多段线：向左偏移后拐角应精确落在两条偏移线的交点上
	var p := GeoPoly.make(PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(100, 100),
	]))
	var o := CurveOps.offset_poly(p, 5.0)
	ok(o != null, "开口多段线应能偏移")
	if o == null:
		return
	ok(o.points.size() == 3, "偏移后顶点数不变")
	# 段0 方向 +X，左侧 +Y -> y=5；段1 方向 +Y，左侧 -X -> x=95
	vclose(o.points[0], Vector2(0, 5), "偏移后起点", 1e-6)
	vclose(o.points[1], Vector2(95, 5), "偏移后拐角（两偏移线交点）", 1e-6)
	vclose(o.points[2], Vector2(95, 100), "偏移后终点", 1e-6)
	close(o.curve_length(), 190.0, "偏移后总长", 1e-6)


func _test_offset_poly_closed() -> void:
	# 逆时针矩形：左侧朝内，故向内偏移成 (5,5)-(95,45)
	var r := GeoPoly.make(PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(100, 50), Vector2(0, 50),
	]), PackedFloat64Array(), true)
	var o := CurveOps.offset_poly(r, 5.0)
	ok(o != null and o.closed, "闭合矩形应能偏移且保持闭合")
	if o == null:
		return
	vclose(o.points[0], Vector2(5, 5), "内偏后角点 0", 1e-6)
	vclose(o.points[1], Vector2(95, 5), "内偏后角点 1", 1e-6)
	vclose(o.points[2], Vector2(95, 45), "内偏后角点 2", 1e-6)
	vclose(o.points[3], Vector2(5, 45), "内偏后角点 3", 1e-6)
	# 反向偏移应向外扩
	var o2 := CurveOps.offset_poly(r, -10.0)
	vclose(o2.points[0], Vector2(-10, -10), "外偏后角点 0", 1e-4)
	close(o2.curve_length(), 2.0 * (120.0 + 70.0), "外偏后周长", 1e-6)


## 偏移圆弧不改变圆心角，因此多段线的 bulge 必须原样保留
func _test_offset_preserves_bulge() -> void:
	var p := GeoPoly.make(PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(100, 100),
	]), PackedFloat64Array([1.0, 0.0]))
	var o := CurveOps.offset_poly(p, 10.0)
	ok(o != null, "含圆弧段的多段线应能偏移")
	if o == null:
		return
	close(o.bulges[0], 1.0, "半圆段的 bulge 偏移后不变", 1e-9)
	close(o.bulges[1], 0.0, "直线段的 bulge 保持 0", 1e-9)
	# 半圆半径由 50 变为 40
	var arc := o.span(0) as GeoArc
	close(arc.radius, 40.0, "偏移后半圆半径 50-10=40", 1e-6)
	# 起点由 (0,0) 内移到 (10,0)
	vclose(o.points[0], Vector2(10, 0), "偏移后弧起点", 1e-4)
	close(o.curve_length(), PI * 40.0 + 100.0, "偏移后总长", 1e-5)


# ---------------------------------------------------------------------------
# 分割与裁剪
# ---------------------------------------------------------------------------

func _test_split_poly() -> void:
	var p := GeoPoly.make(PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(100, 100),
	]))
	var total := p.curve_length()
	var res := CurveOps.split_poly_at_dist(p, 40.0)
	ok(res.size() == 2, "切分应得两段")
	if res.size() != 2:
		return
	vclose(res[0].points[res[0].points.size() - 1], Vector2(40, 0), "切分点位置", 1e-6)
	close(res[0].curve_length(), 40.0, "前半段长度", 1e-6)
	close(res[1].curve_length(), total - 40.0, "后半段长度", 1e-6)
	close(res[0].curve_length() + res[1].curve_length(), total, "切分后总长不变", 1e-6)

	# 切点在圆弧段上时 bulge 要按比例重算
	var pa := GeoPoly.make(PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(100, 100),
	]), PackedFloat64Array([1.0, 0.0]))
	var half := PI * 50.0 * 0.5
	var ra := CurveOps.split_poly_at_dist(pa, half)
	ok(ra.size() == 2, "圆弧段切分应得两段")
	if ra.size() != 2:
		return
	# 半圆切成两半后各为 90° 弧，bulge = tan(90/4) = tan(22.5°)
	close(ra[0].bulges[0], tan(deg_to_rad(22.5)), "前半段 bulge 对应 90° 弧", 1e-5)
	close(ra[1].bulges[0], tan(deg_to_rad(22.5)), "后半段 bulge 对应 90° 弧", 1e-5)
	close(ra[0].curve_length() + ra[1].curve_length(), pa.curve_length(), "圆弧切分后总长不变", 1e-5)


func _test_slice_and_remove() -> void:
	var p := GeoPoly.make(PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(100, 100),
	]))
	# 取 [30, 150]：即从 (30,0) 到 (100,80)
	var sl := CurveOps.slice_poly(p, 30.0, 150.0)
	vclose(sl.start_point(), Vector2(30, 0), "切片起点", 1e-4)
	vclose(sl.end_point(), Vector2(100, 50), "切片终点", 1e-4)
	close(sl.curve_length(), 120.0, "切片长度", 1e-6)
	# 全区间应原样返回
	var full := CurveOps.slice_poly(p, 0.0, p.curve_length())
	close(full.curve_length(), p.curve_length(), "全区间切片长度", 1e-6)
	# 区间反序应自动纠正
	var rev := CurveOps.slice_poly(p, 150.0, 30.0)
	close(rev.curve_length(), 120.0, "倒序区间应被纠正", 1e-6)
	# 移除中段 [40, 160] -> 剩两段
	var rem := CurveOps.remove_range_poly(p, 40.0, 160.0)
	ok(rem.size() == 2, "移除中段应剩两段，实际 %d" % rem.size())
	if rem.size() == 2:
		close(rem[0].curve_length(), 40.0, "剩余前段长度", 1e-6)
		close(rem[1].curve_length(), 40.0, "剩余后段长度", 1e-4)
	# 从起点移除只剩一段
	var rem2 := CurveOps.remove_range_poly(p, 0.0, 100.0)
	ok(rem2.size() == 1, "从起点移除应只剩一段，实际 %d" % rem2.size())
	if rem2.size() == 1:
		vclose(rem2[0].start_point(), Vector2(100, 0), "剩余段起点", 1e-6)


# ---------------------------------------------------------------------------
# 圆角与倒角
# ---------------------------------------------------------------------------

func _test_fillet() -> void:
	# 直角：水平线 x 轴、竖直线 y 轴，在原点相交
	var sa := GeoSeg.make(Vector2(-50, 0), Vector2(50, 0))
	var sb := GeoSeg.make(Vector2(0, -50), Vector2(0, 50))
	var r := 20.0
	var res := CurveOps.fillet_segs(sa, sb, r, Vector2(30, 0), Vector2(0, 30))
	ok(res.get("ok", false), "直角处应能倒圆角")
	if not res.get("ok", false):
		return
	# 切线长 = r / tan(45°) = r
	vclose(res["tangent_a"], Vector2(r, 0), "切点 A", 1e-6)
	vclose(res["tangent_b"], Vector2(0, r), "切点 B", 1e-6)
	vclose(res["center"], Vector2(r, r), "圆角圆心", 1e-6)
	var arc := res["arc"] as GeoArc
	close(arc.radius, r, "圆角半径")
	close(arc.sweep(), PI * 0.5, "直角对应 90° 圆角弧")
	# 切点到圆心距离必须等于半径（切线性质）
	ok(absf((res["tangent_a"] as Vector2).distance_to(res["center"]) - r) < 1e-6, "切点 A 在圆上")
	ok(absf((res["tangent_b"] as Vector2).distance_to(res["center"]) - r) < 1e-6, "切点 B 在圆上")

	# 平行线段无法倒圆角
	var par := CurveOps.fillet_segs(
		GeoSeg.make(Vector2(0, 0), Vector2(100, 0)),
		GeoSeg.make(Vector2(0, 10), Vector2(100, 10)), 5.0, Vector2(50, 0), Vector2(50, 10))
	ok(not par.get("ok", false), "平行线段不应倒出圆角")


func _test_fillet_sharp_angle() -> void:
	# 60° 夹角：切线长 = r / tan(30°)，圆心到角点的距离 = r / sin(30°)
	var sc := GeoSeg.make(Vector2(0, 0), Vector2(100, 0))
	var dir := Vector2(cos(deg_to_rad(60)), sin(deg_to_rad(60)))
	var sd := GeoSeg.make(Vector2(0, 0), dir * 100.0)
	var r := 10.0
	var res := CurveOps.fillet_segs(sc, sd, r, Vector2(50, 0), dir * 50.0)
	ok(res.get("ok", false), "60° 夹角应能倒圆角")
	if not res.get("ok", false):
		return
	var tan_len := r / tan(deg_to_rad(30.0))
	close((res["tangent_a"] as Vector2).distance_to(Vector2.ZERO), tan_len, "60° 夹角的切线长", 1e-5)
	vclose(res["tangent_a"], Vector2(tan_len, 0), "切点 A 在水平线上", 1e-5)
	close((res["center"] as Vector2).distance_to(Vector2.ZERO), r / sin(deg_to_rad(30.0)),
		"圆心到角点距离 = r/sin(半角)", 1e-5)
	ok(absf((res["tangent_a"] as Vector2).distance_to(res["center"]) - r) < 1e-5, "切点 A 在圆上")
	ok(absf((res["tangent_b"] as Vector2).distance_to(res["center"]) - r) < 1e-5, "切点 B 在圆上")
	close((res["arc"] as GeoArc).sweep(), PI - deg_to_rad(60.0), "圆角弧扫掠角 = PI - 夹角", 1e-5)


func _test_chamfer() -> void:
	var sa := GeoSeg.make(Vector2(-50, 0), Vector2(50, 0))
	var sb := GeoSeg.make(Vector2(0, -50), Vector2(0, 50))
	var res := CurveOps.chamfer_segs(sa, sb, 15.0, 15.0, Vector2(30, 0), Vector2(0, 30))
	ok(res.get("ok", false), "直角处应能倒角")
	if not res.get("ok", false):
		return
	vclose(res["cut_a"], Vector2(15, 0), "倒角切点 A", 1e-6)
	vclose(res["cut_b"], Vector2(0, 15), "倒角切点 B", 1e-6)
	var res2 := CurveOps.chamfer_segs(sa, sb, 10.0, 25.0, Vector2(30, 0), Vector2(0, 30))
	vclose(res2["cut_a"], Vector2(10, 0), "不等距倒角 A", 1e-6)
	vclose(res2["cut_b"], Vector2(0, 25), "不等距倒角 B", 1e-6)


# ---------------------------------------------------------------------------
# 延伸定位与连接
# ---------------------------------------------------------------------------

func _test_crossings_sorted() -> void:
	# 一条水平线穿过两条竖线，交点弧长位置应为 30 与 70，且按序返回
	var target := GeoSeg.make(Vector2(0, 0), Vector2(100, 0))
	var b1 := GeoSeg.make(Vector2(70, -10), Vector2(70, 10))
	var b2 := GeoSeg.make(Vector2(30, -10), Vector2(30, 10))
	var bounds: Array[GeoCurve] = [b1, b2]
	var cr := CurveOps.crossings_sorted(target, bounds, false)
	ok(cr.size() == 2, "应有 2 个交点，实际 %d" % cr.size())
	if cr.size() == 2:
		close(float(cr[0][0]), 30.0, "第一个交点弧长", 1e-4)
		close(float(cr[1][0]), 70.0, "第二个交点弧长", 1e-4)
	# 不延伸时曲线外的边界不应产生交点
	var far := GeoSeg.make(Vector2(200, -10), Vector2(200, 10))
	var far_a: Array[GeoCurve] = [far]
	ok(CurveOps.crossings_sorted(target, far_a, false).is_empty(), "不延伸时曲线外的边界无交点")
	# 延伸求出的越界交点应被过滤
	ok(CurveOps.crossings_sorted(target, far_a, true).is_empty(), "越界交点应被过滤")


func _test_try_join() -> void:
	var a := GeoPoly.make(PackedVector2Array([Vector2(0, 0), Vector2(100, 0)]))
	var b := GeoPoly.make(PackedVector2Array([Vector2(100, 0), Vector2(100, 100)]))
	var j := CurveOps.try_join(a, b)
	ok(j != null, "首尾相接的多段线应能连接")
	if j != null:
		ok(j.points.size() == 3, "连接后应有 3 个顶点，实际 %d" % j.points.size())
		close(j.curve_length(), 200.0, "连接后长度", 1e-6)
	# 反向相接也应能连接
	var c := GeoPoly.make(PackedVector2Array([Vector2(100, 100), Vector2(100, 0)]))
	var j2 := CurveOps.try_join(a, c)
	ok(j2 != null, "反向相接应能连接")
	if j2 != null:
		close(j2.curve_length(), 200.0, "反向连接后长度", 1e-6)
		vclose(j2.end_point(), Vector2(100, 100), "反向连接后终点", 1e-6)
	# 不相接的不能连接
	var d := GeoPoly.make(PackedVector2Array([Vector2(500, 500), Vector2(600, 600)]))
	ok(CurveOps.try_join(a, d) == null, "不相接的多段线不应连接")


# ---------------------------------------------------------------------------
# 求交
# ---------------------------------------------------------------------------

func _test_intersect_entities() -> void:
	var l1 := EntLine.make(Vector2(0, 0), Vector2(100, 100))
	var l2 := EntLine.make(Vector2(0, 100), Vector2(100, 0))
	var pts := CurveOps.intersect_entities(l1, l2)
	ok(pts.size() == 1, "两条交叉直线应有 1 个交点，实际 %d" % pts.size())
	if pts.size() == 1:
		vclose(pts[0], Vector2(50, 50), "交点坐标", 1e-5)

	# 直线与圆：过圆心的直线交于两点
	var ci := EntCircle.make(Vector2(0, 0), 10.0)
	var ln := EntLine.make(Vector2(-50, 0), Vector2(50, 0))
	var pts2 := CurveOps.intersect_entities(ci, ln)
	ok(pts2.size() == 2, "圆与过圆心直线应有 2 个交点，实际 %d" % pts2.size())

	# 多段线与直线：多段线要逐段参与求交
	var pl := EntPolyline.make(PackedVector2Array([
		Vector2(0, 0), Vector2(50, 0), Vector2(50, 50),
	]))
	var ln2 := EntLine.make(Vector2(25, -10), Vector2(25, 10))
	var pts3 := CurveOps.intersect_entities(pl, ln2)
	ok(pts3.size() == 1, "多段线与直线应有 1 个交点，实际 %d" % pts3.size())
	if pts3.size() == 1:
		vclose(pts3[0], Vector2(25, 0), "多段线交点", 1e-6)

	# 带圆弧段的多段线：圆弧段也要参与求交
	var pla := EntPolyline.make(
		PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 100)]),
		PackedFloat64Array([1.0, 0.0]))
	var ln3 := EntLine.make(Vector2(50, -100), Vector2(50, 100))
	var pts4 := CurveOps.intersect_entities(pla, ln3)
	# 半圆（圆心 (50,0) 半径 50）与竖直线 x=50 交于 (50,50) 与 (50,-50)，
	# 但 (-50) 一侧不在半圆上（半圆位于 y<=0 半平面），故只有 (50,-50)
	ok(pts4.size() >= 1, "带圆弧段的多段线应能求交，实际 %d" % pts4.size())
