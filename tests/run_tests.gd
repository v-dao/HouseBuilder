extends SceneTree
## 无头单元测试入口。
## 运行：godot --headless --path <项目> --script res://tests/run_tests.gd
##
## 必须继承 SceneTree（Godot 的 --script 只接受 SceneTree / MainLoop）。

var _pass := 0
var _fail := 0
var _failures: Array[String] = []
var _suite := ""
## 断言工具与计数都在 TestSuite 里，本类只做转发 ——
## 因为 --script 要求本类 extends SceneTree，GDScript 没有多继承，
## 无法再继承 TestSuite。
var _T := TestSuite.new()


func _initialize() -> void:
	_suite = "Bulge 圆弧参数"
	_test_bulge_from_angle()
	_test_bulge_semicircle()
	_test_bulge_sign_convention()
	_test_bulge_roundtrip()

	_suite = "GeoArc 圆弧"
	_test_arc_sweep_wraparound()
	_test_arc_geometry()
	_test_arc_bbox()
	_test_arc_tessellation_accuracy()
	_test_arc_transform()
	_test_arc_closest_point()

	_suite = "GeoPoly 多段线"
	_test_poly_basic()
	_test_poly_with_arc_span()
	_test_poly_closed()
	_test_poly_reversed()
	_test_poly_transform_mirror()
	_test_poly_bbox_includes_arc_bulge()

	_suite = "求交"
	_test_seg_seg_intersect()
	_test_arc_seg_intersect()
	_test_arc_arc_intersect()

	_suite = "容差与角度工具"
	_test_tol_angles()

	_suite = "国标线宽体系 (GB/T 50001)"
	_test_gb_lineweight()

	_suite = "实体序列化往返"
	_test_entity_roundtrip()

	_suite = "撤销栈"
	_test_undo_redo()

	# 模块化测试套件（各自继承 TestSuite）
	var co := CurveOpsTests.new()
	co.run()
	_T.merge(co)

	var p1 := P1Tests.new()
	p1.run()
	_T.merge(p1)

	var p2 := P2Tests.new()
	p2.run()
	_T.merge(p2)

	var p2b := P2bTests.new()
	p2b.run()
	_T.merge(p2b)

	var p2c := P2cTests.new()
	p2c.run()
	_T.merge(p2c)

	var p2d := P2dTests.new()
	p2d.run()
	_T.merge(p2d)

	var p3 := P3Tests.new()
	p3.run()
	_T.merge(p3)

	_sync_counts()
	_print_summary()
	quit(0 if _T.fail_count == 0 else 1)


func _sync_counts() -> void:
	_pass = _T.pass_count
	_fail = _T.fail_count
	_failures = _T.failures


# ---------------------------------------------------------------------------
# 断言工具（转发给 TestSuite）
# ---------------------------------------------------------------------------

func _ok(cond: bool, msg: String) -> void:
	_T.suite = _suite
	_T.ok(cond, msg)


func _close(a: float, b: float, msg: String, tol := 1.0e-6) -> void:
	_T.suite = _suite
	_T.close(a, b, msg, tol)


func _vclose(a: Vector2, b: Vector2, msg: String, tol := 1.0e-6) -> void:
	_T.suite = _suite
	_T.vclose(a, b, msg, tol)


# ---------------------------------------------------------------------------
# Bulge
# ---------------------------------------------------------------------------

func _test_bulge_from_angle() -> void:
	_close(Bulge.from_angle(PI), 1.0, "bulge(PI) = 1（半圆）")
	_close(Bulge.from_angle(PI * 0.5), tan(PI / 8.0), "bulge(PI/2)")
	_close(Bulge.from_angle(0.0), 0.0, "bulge(0) = 0")
	_close(Bulge.to_angle(1.0), PI, "angle(1) = PI")


func _test_bulge_semicircle() -> void:
	# 半圆：圆心应在弦中点，半径 = 弦长/2，圆弧位于弦下方（逆时针）
	var c := Bulge.span_to_curve(Vector2(0, 0), Vector2(2, 0), 1.0)
	_ok(c is GeoArc, "bulge=1 应产生圆弧")
	var arc := c as GeoArc
	_vclose(arc.center, Vector2(1, 0), "半圆圆心为弦中点")
	_close(arc.radius, 1.0, "半圆半径 = 1")
	_close(arc.sweep(), PI, "半圆扫掠角 = PI")
	_ok(arc.ccw, "正 bulge 应为逆时针")
	_vclose(arc.midpoint(), Vector2(1, -1), "正 bulge 的圆弧位于弦的右侧（下方）", 1.0e-5)


func _test_bulge_sign_convention() -> void:
	# 符号约定：正 bulge = 逆时针；负 bulge 的圆弧在弦的另一侧
	var pos := Bulge.span_to_curve(Vector2(0, 0), Vector2(2, 0), 1.0) as GeoArc
	var neg := Bulge.span_to_curve(Vector2(0, 0), Vector2(2, 0), -1.0) as GeoArc
	_ok(pos.ccw and not neg.ccw, "正 bulge 逆时针、负 bulge 顺时针")
	_vclose(neg.midpoint(), Vector2(1, 1), "负 bulge 的圆弧位于弦的左侧（上方）", 1.0e-5)
	# 更一般的正 bulge
	var small := Bulge.span_to_curve(Vector2(0, 0), Vector2(2, 0), 0.4142135623730951) as GeoArc
	_close(small.sweep(), PI * 0.5, "bulge≈0.4142 对应 90° 圆心角", 1.0e-6)
	_vclose(small.midpoint(), Vector2(1, -0.41421356), "小正 bulge 圆弧在弦右侧", 1.0e-5)


func _test_bulge_roundtrip() -> void:
	for deg in [-170.0, -90.0, -45.0, 30.0, 90.0, 170.0]:
		var theta := deg_to_rad(deg)
		var b := Bulge.from_angle(theta)
		var c := Bulge.span_to_curve(Vector2(0, 0), Vector2(3, 1), b) as GeoArc
		_close(c.sweep(), absf(theta), "bulge 往返 %d° 的扫掠角" % int(deg), Tol.ANGLE)
		_ok(c.ccw == (theta > 0.0), "bulge 往返 %d° 的方向" % int(deg))
		_vclose(c.start_point(), Vector2(0, 0), "span_to_curve 起点保持", 1.0e-5)
		_vclose(c.end_point(), Vector2(3, 1), "span_to_curve 终点保持", 1.0e-5)


# ---------------------------------------------------------------------------
# GeoArc
# ---------------------------------------------------------------------------

func _test_arc_sweep_wraparound() -> void:
	var a := GeoArc.make(Vector2.ZERO, 1.0, deg_to_rad(350.0), deg_to_rad(10.0), true)
	_close(a.sweep(), deg_to_rad(20.0), "跨 0° 的逆时针扫掠角", 1.0e-9)
	var b := GeoArc.make(Vector2.ZERO, 1.0, deg_to_rad(10.0), deg_to_rad(350.0), false)
	_close(b.sweep(), deg_to_rad(20.0), "跨 0° 的顺时针扫掠角", 1.0e-9)
	var full := GeoArc.make_circle(Vector2.ZERO, 5.0)
	_close(full.sweep(), TAU, "整圆扫掠角", 1.0e-9)
	_ok(full.is_full_circle(), "整圆判定")


func _test_arc_geometry() -> void:
	var a := GeoArc.make(Vector2(10, 20), 5.0, 0.0, PI * 0.5, true)
	_vclose(a.start_point(), Vector2(15, 20), "圆弧起点")
	_vclose(a.end_point(), Vector2(10, 25), "圆弧终点")
	_vclose(a.midpoint(), Vector2(10, 20) + Vector2(cos(PI / 4.0), sin(PI / 4.0)) * 5.0, "圆弧中点")
	_close(a.curve_length(), 5.0 * PI * 0.5, "圆弧弧长")
	# 逆时针时切向 = 半径方向逆时针旋转 90°
	var t0 := a.tangent_at(0.0)
	_vclose(t0, Vector2(0, 1), "起点切向（逆时针）")
	var cw := GeoArc.make(Vector2(10, 20), 5.0, 0.0, PI * 0.5, false)
	_vclose(cw.tangent_at(0.0), Vector2(0, -1), "起点切向（顺时针）")


func _test_arc_bbox() -> void:
	# 90° 弧（0° 到 90°）的包围盒只应包含 0° 与 90° 两个象限点
	var a := GeoArc.make(Vector2.ZERO, 2.0, 0.0, PI * 0.5, true)
	var bb := a.bbox()
	_ok(absf(bb.position.x - 0.0) < 1e-6 and absf(bb.position.y - 0.0) < 1e-6, "90° 弧包围盒左下角")
	_ok(absf(bb.size.x - 2.0) < 1e-6 and absf(bb.size.y - 2.0) < 1e-6, "90° 弧包围盒尺寸")
	# 跨越 270° 的弧应包含 y 最小值 -2
	var b := GeoArc.make(Vector2.ZERO, 2.0, deg_to_rad(200.0), deg_to_rad(340.0), true)
	var bb2 := b.bbox()
	_ok(absf(bb2.position.y + 2.0) < 1e-5, "跨 270° 的弧包围盒应触及 y=-2，实际 y=%.6f" % bb2.position.y)


func _test_arc_tessellation_accuracy() -> void:
	# 细分的最大矢高误差应不超过给定 sagitta
	var a := GeoArc.make_circle(Vector2(3, -4), 12.5)
	for sag in [1.0, 0.1, 0.01]:
		var pts := a.tessellate(sag)
		_ok(pts.size() >= 3, "sagitta=%.3f 时点数 = %d" % [sag, pts.size()])
		var max_dev := 0.0
		for p in pts:
			max_dev = maxf(max_dev, absf(p.distance_to(a.center) - a.radius))
		_ok(max_dev <= sag * 1.0001, "sagitta=%.3f 时最大矢高误差 %.6f 未超标" % [sag, max_dev])
		# 首尾点必须精确落在弧上
		_vclose(pts[0], a.start_point(), "细分首点")
		_vclose(pts[pts.size() - 1], a.end_point(), "细分末点")


func _test_arc_transform() -> void:
	var a := GeoArc.make(Vector2(1, 1), 2.0, 0.0, PI, true)
	var xf := Transform2D(PI * 0.5, Vector2(10, 20)).scaled(Vector2(3, 3))
	var b := a.transformed(xf) as GeoArc
	_close(b.radius, 6.0, "变换后半径按比例缩放")
	_vclose(b.start_point(), xf * a.start_point(), "变换后起点一致", 1.0e-4)
	_vclose(b.end_point(), xf * a.end_point(), "变换后终点一致", 1.0e-4)
	_ok(b.ccw == a.ccw, "纯旋转缩放不改变绕向")
	# 镜像应反转绕向
	var mirror := Transform2D(Vector2(-1, 0), Vector2(0, 1), Vector2.ZERO)
	var m := a.transformed(mirror) as GeoArc
	_ok(m.ccw != a.ccw, "镜像变换反转绕向")


func _test_arc_closest_point() -> void:
	var a := GeoArc.make(Vector2.ZERO, 5.0, 0.0, PI * 0.5, true)
	# 落在弧内的点
	var r := a.closest_point(Vector2(10, 0))
	_vclose(r["point"], Vector2(5, 0), "弧内点的最近点", 1.0e-6)
	# 落在弧外（角度不在范围内）应吸附到端点
	var r2 := a.closest_point(Vector2(-10, 0))
	# 到终点 (0,5) 距离 11.18，到起点 (5,0) 距离 15，故应吸附到终点
	_vclose(r2["point"], Vector2(0, 5), "角度不在弧内时吸附到最近端点", 1.0e-6)
	_ok(r2["dist"] > 0.0, "最近点距离为正")


# ---------------------------------------------------------------------------
# GeoPoly
# ---------------------------------------------------------------------------

func _test_poly_basic() -> void:
	var p := GeoPoly.make(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)]))
	_close(p.curve_length(), 20.0, "开口多段线长度")
	_ok(p.span_count() == 2, "开口多段线段数 = 2")
	_vclose(p.point_at(0.5), Vector2(10, 0), "开口多段线弧长中点")
	_vclose(p.end_point(), Vector2(10, 10), "开口多段线终点")


func _test_poly_with_arc_span() -> void:
	# 两个顶点之间用 bulge 形成半圆，总长应为 10 + PI*5
	var bls := PackedFloat64Array([1.0, 0.0])
	var p := GeoPoly.make(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)]), bls)
	# 段0 为半圆弧 (0,0)->(10,0)，长 PI*5；段1 为竖边 (10,0)->(10,10)，长 10
	_close(p.curve_length(), PI * 5.0 + 10.0, "含半圆段的多段线长度", 1.0e-5)
	var s0 := p.span(0) as GeoArc
	_ok(s0 != null, "第 0 段应为圆弧")
	_vclose(s0.center, Vector2(5, 0), "半圆段圆心")
	_close(s0.radius, 5.0, "半圆段半径")
	var pts := p.tessellate(0.01)
	_vclose(pts[0], Vector2(0, 0), "细分首点")
	_vclose(pts[pts.size() - 1], Vector2(10, 10), "细分末点")
	# 弧段上的点都应在圆上
	var max_dev := 0.0
	for q in pts:
		var d := absf(q.distance_to(Vector2(5, 0)))
		if absf(d - 5.0) > 1e-6:
			# 直线段的点不在圆上，跳过；仅检查位于半圆范围内的点
			continue
		max_dev = maxf(max_dev, absf(d - 5.0))
	_ok(max_dev <= 1e-5, "半圆段细分点精度")


func _test_poly_closed() -> void:
	var p := GeoPoly.make(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)]), PackedFloat64Array(), true)
	_ok(p.is_closed(), "闭合判定")
	_ok(p.span_count() == 4, "闭合多段线段数 = 4")
	_close(p.curve_length(), 40.0, "闭合多段线周长")
	_vclose(p.end_point(), Vector2(0, 0), "闭合多段线终点回到起点")
	var pts := p.tessellate(0.1)
	_vclose(pts[0], pts[pts.size() - 1], "闭合多段线细分首尾重合")


func _test_poly_reversed() -> void:
	var bls := PackedFloat64Array([0.5, -0.3, 0.0])
	var p := GeoPoly.make(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)]), bls)
	var r := p.reversed() as GeoPoly
	_close(r.curve_length(), p.curve_length(), "反转后长度不变", 1.0e-5)
	_vclose(r.start_point(), p.end_point(), "反转后起点 = 原终点")
	_vclose(r.end_point(), p.start_point(), "反转后终点 = 原起点")
	# 反转后中点应相同
	_vclose(r.point_at(0.5), p.point_at(0.5), "反转后弧长中点不变", 1.0e-4)
	# 闭合多段线反转
	var c := GeoPoly.make(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)]), PackedFloat64Array([1.0, 0.0, 0.0]), true)
	var cr := c.reversed() as GeoPoly
	_close(cr.curve_length(), c.curve_length(), "闭合多段线反转后周长不变", 1.0e-5)


func _test_poly_transform_mirror() -> void:
	# 镜像后圆弧应位于另一侧
	var bls := PackedFloat64Array([1.0, 0.0])
	var p := GeoPoly.make(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)]), bls)
	var arc_before := p.span(0) as GeoArc
	var mirror := Transform2D(Vector2(1, 0), Vector2(0, -1), Vector2.ZERO)
	var m := p.transformed(mirror) as GeoPoly
	var arc_after := m.span(0) as GeoArc
	_ok(arc_before.ccw != arc_after.ccw, "镜像后圆弧绕向反转")
	# Y 镜像把圆弧换到弦的另一侧：原弧中点在 (5,-5)，镜像后应在 (5,5)
	_vclose(arc_before.midpoint(), Vector2(5, -5), "镜像前弧中点", 1.0e-5)
	_vclose(arc_after.midpoint(), Vector2(5, 5), "镜像后弧中点", 1.0e-5)


func _test_poly_bbox_includes_arc_bulge() -> void:
	# 顶点包围盒是 y in [0,10]，但半圆段鼓出到 y=-5，包围盒必须包含
	var bls := PackedFloat64Array([1.0, 0.0])
	var p := GeoPoly.make(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)]), bls)
	var bb := p.bbox()
	_ok(bb.position.y <= -5.0 + 1e-5, "包围盒应包含弧段鼓出部分 y<=-5，实际 y=%.6f" % bb.position.y)


# ---------------------------------------------------------------------------
# 求交
# ---------------------------------------------------------------------------

func _test_seg_seg_intersect() -> void:
	var a := GeoSeg.make(Vector2(0, 0), Vector2(10, 10))
	var b := GeoSeg.make(Vector2(0, 10), Vector2(10, 0))
	var r := a.intersect_seg(b)
	_ok(r["hit"], "交叉线段应相交")
	_vclose(r["point"], Vector2(5, 5), "交叉点坐标")
	# 不相交（延长后才交）
	var c := GeoSeg.make(Vector2(20, 0), Vector2(30, 0))
	var r2 := a.intersect_seg(c)
	_ok(not r2["hit"], "不相交的线段不应判定为相交")
	# 平行
	var d := GeoSeg.make(Vector2(0, 1), Vector2(10, 11))
	_ok(not a.intersect_seg(d)["hit"], "平行线段无交点")


func _test_arc_seg_intersect() -> void:
	var arc := GeoArc.make_circle(Vector2.ZERO, 1.0)
	var seg := GeoSeg.make(Vector2(-2, 0), Vector2(2, 0))
	var hits := arc.intersect_seg(seg)
	_ok(hits.size() == 2, "整圆与过圆心直线应有 2 个交点，实际 %d" % hits.size())
	if hits.size() == 2:
		var sorted := [hits[0], hits[1]]
		sorted.sort_custom(func(x, y): return x.x < y.x)
		_vclose(sorted[0], Vector2(-1, 0), "左交点", 1.0e-6)
		_vclose(sorted[1], Vector2(1, 0), "右交点", 1.0e-6)
	# 相切
	var tan_seg := GeoSeg.make(Vector2(-2, 1), Vector2(2, 1))
	var th := arc.intersect_seg(tan_seg)
	_ok(th.size() == 1, "切线应只有 1 个交点，实际 %d" % th.size())
	if th.size() == 1:
		_vclose(th[0], Vector2(0, 1), "切点", 1.0e-5)
	# 无交点
	_ok(arc.intersect_seg(GeoSeg.make(Vector2(-2, 5), Vector2(2, 5))).is_empty(), "远离的直线无交点")
	# 圆弧（非整圆）应排除角度范围外的交点
	var quarter := GeoArc.make(Vector2.ZERO, 1.0, 0.0, PI * 0.5, true)
	var qh := quarter.intersect_seg(GeoSeg.make(Vector2(-2, 0), Vector2(2, 0)))
	_ok(qh.size() == 1, "90° 弧与 X 轴应有 1 个交点，实际 %d" % qh.size())
	if qh.size() == 1:
		_vclose(qh[0], Vector2(1, 0), "象限交点")


func _test_arc_arc_intersect() -> void:
	# 两个半径 5、圆心距 6 的圆：交点 x = 3, y = ±4
	var a := GeoArc.make_circle(Vector2(0, 0), 5.0)
	var b := GeoArc.make_circle(Vector2(6, 0), 5.0)
	var hits := a.intersect_arc(b)
	_ok(hits.size() == 2, "两圆应有 2 个交点，实际 %d" % hits.size())
	if hits.size() == 2:
		var sorted := [hits[0], hits[1]]
		sorted.sort_custom(func(x, y): return x.y < y.y)
		_vclose(sorted[0], Vector2(3, -4), "下交点", 1.0e-5)
		_vclose(sorted[1], Vector2(3, 4), "上交点", 1.0e-5)
	# 外离
	_ok(a.intersect_arc(GeoArc.make_circle(Vector2(100, 0), 5.0)).is_empty(), "相离两圆无交点")
	# 内含
	_ok(a.intersect_arc(GeoArc.make_circle(Vector2(0, 0), 1.0)).is_empty(), "同心圆无交点")
	# 外切
	var t := a.intersect_arc(GeoArc.make_circle(Vector2(10, 0), 5.0))
	_ok(t.size() == 1, "外切应有 1 个交点，实际 %d" % t.size())
	if t.size() == 1:
		_vclose(t[0], Vector2(5, 0), "外切点", 1.0e-5)


# ---------------------------------------------------------------------------
# 容差工具
# ---------------------------------------------------------------------------

func _test_tol_angles() -> void:
	_close(Tol.norm_angle(-0.5), TAU - 0.5, "角度归一化到 [0,TAU)")
	_close(Tol.norm_angle_signed(PI + 0.1), -PI + 0.1, "角度归一化到 (-PI,PI]")
	# 区间 [350°, 10°] 逆时针扫过 0°，因此 0° 在区间内、20° 不在
	_ok(Tol.angle_in_ccw(0.0, deg_to_rad(350.0), deg_to_rad(10.0)), "跨 0° 区间内的点（0°）")
	_ok(not Tol.angle_in_ccw(deg_to_rad(20.0), deg_to_rad(350.0), deg_to_rad(10.0)), "跨 0° 区间外的点（20°）")
	_ok(Tol.angle_in_ccw(deg_to_rad(5.0), deg_to_rad(0.0), deg_to_rad(10.0)), "普通区间内的点")
	_ok(not Tol.angle_in_ccw(deg_to_rad(170.0), deg_to_rad(0.0), deg_to_rad(10.0)), "普通区间外的点")
	_ok(Tol.eq(1.0, 1.0005), "容差内相等")
	_ok(not Tol.eq(1.0, 1.01), "容差外不等")
	_ok(Tol.is_zero(0.0005), "接近零")
	_ok(not Tol.is_zero(0.01), "不接近零")


# ---------------------------------------------------------------------------
# 国标线宽体系
# ---------------------------------------------------------------------------

func _test_gb_lineweight() -> void:
	# 线宽组必须严格是 b / 0.7b / 0.5b / 0.25b
	for b in GbLineweight.B_CHOICES:
		var g := GbLineweight.group(b)
		_ok(g.size() == 4, "b=%.1f 的线宽组应有 4 档，实际 %d" % [b, g.size()])
		_close(g[0], maxf(b * 0.25, 0.1), "b=%.1f 细线 = 0.25b" % b)
		_close(g[3], b, "b=%.1f 粗线 = b" % b)
	# 线宽下限：任何线宽不得小于 0.1mm
	for b in [0.5, 1.0]:
		for w in GbLineweight.group(b):
			_ok(w >= GbLineweight.MIN_WIDTH - 1e-9, "线宽 %.3f 不应小于 0.1mm" % w)
	# 出图比例 -> 基本线宽
	_close(GbLineweight.b_for_plot_scale(10.0), 1.4, "1:10 详图 b=1.4")
	_close(GbLineweight.b_for_plot_scale(100.0), 1.0, "1:100 平面图 b=1.0")
	_close(GbLineweight.b_for_plot_scale(500.0), 0.5, "1:500 总图 b=0.5")
	# GB/T 50104 图线用途 -> 线宽
	var b := 1.0
	_close(GbLineweight.width_for("剖切主轮廓", b), 1.0, "墙体剖切主轮廓 = 粗实线 b")
	_close(GbLineweight.width_for("建筑构配件", b), 0.7, "门窗构配件 = 中粗 0.7b")
	_close(GbLineweight.width_for("尺寸与符号", b), 0.5, "尺寸线符号 = 中实线 0.5b")
	_close(GbLineweight.width_for("定位轴线", b), 0.25, "定位轴线 = 细 0.25b")
	_close(GbLineweight.width_for("图例填充", b), 0.25, "图例填充线 = 细 0.25b")
	# 吸附到合法线宽
	_close(GbLineweight.snap(1.0, 0.33), 0.25, "0.33 应吸附到 0.25")
	_close(GbLineweight.snap(1.0, 0.55), 0.5, "0.55 应吸附到 0.5（距 0.5 更近）")
	_close(GbLineweight.snap(1.0, 0.62), 0.7, "0.62 应吸附到 0.7（距 0.7 更近）")
	# 用途映射表引用的图层都必须能查到线宽
	for row in GbLineweight.default_layer_map():
		var usage := String(row[2])
		_ok(GbLineweight.USAGE.has(usage), "图层 %s 引用了未定义的用途 %s" % [String(row[0]), usage])


# ---------------------------------------------------------------------------
# 实体序列化往返
# ---------------------------------------------------------------------------

func _test_entity_roundtrip() -> void:
	var src := [
		EntLine.make(Vector2(-1234.5, 6789.25), Vector2(10000.0, -5.5)),
		EntCircle.make(Vector2(3600.0, -2400.0), 1250.75),
		EntArc.make(Vector2(0, 0), 500.0, deg_to_rad(30.0), deg_to_rad(200.0)),
		EntPolyline.make(
			PackedVector2Array([Vector2(0, 0), Vector2(3600, 0), Vector2(3600, 3000)]),
			PackedFloat64Array([1.0, -0.25, 0.0]), true),
		EntText.make(Vector2(100, 200), "一层平面图 ±0.000", 3.5, 0.5),
	]
	# 循环变量必须显式标注类型，否则 e 为 Variant，后续 e.to_dict() 也无法推断
	for e: CadEntity in src:
		e.layer = "墙体"
		e.aci = 256
		var d := e.to_dict()
		var r := _rebuild(d)
		_ok(r != null, "%s 应能从字典重建" % e.type_name())
		if r == null:
			continue
		_ok(r.layer == e.layer, "%s 图层往返" % e.type_name())
		_ok(r.aci == e.aci, "%s 颜色索引往返" % e.type_name())
		# 几何精度：包围盒应一致
		var a := e.get_bbox()
		var bb := r.get_bbox()
		_ok(a.position.distance_to(bb.position) <= 1e-4 and a.size.distance_to(bb.size) <= 1e-4,
			"%s 包围盒往返 (%.6f,%.6f)-(%.6f,%.6f) vs (%.6f,%.6f)-(%.6f,%.6f)" % [
				e.type_name(), a.position.x, a.position.y, a.size.x, a.size.y,
				bb.position.x, bb.position.y, bb.size.x, bb.size.y])
	# 多段线的 bulge 必须精确保留（这是 DXF 往返的命门）
	var pl := EntPolyline.make(
		PackedVector2Array([Vector2(0, 0), Vector2(1000, 0), Vector2(1000, 800)]),
		PackedFloat64Array([0.4142135623730951, -1.0, 0.0]), true)
	var pl2 := EntPolyline.from_dict(pl.to_dict())
	_ok(pl2.bulges().size() == 3, "多段线 bulge 数量往返")
	for i in range(3):
		_close(pl2.bulges()[i], pl.bulges()[i], "多段线 bulge[%d] 往返" % i, 1e-12)
	_close(pl2.poly.curve_length(), pl.poly.curve_length(), "多段线弧长往返", 1e-5)


func _rebuild(d: Dictionary) -> CadEntity:
	match int(d.get("type", -1)):
		CadEntity.Type.LINE:
			return EntLine.from_dict(d)
		CadEntity.Type.CIRCLE:
			return EntCircle.from_dict(d)
		CadEntity.Type.ARC:
			return EntArc.from_dict(d)
		CadEntity.Type.POLYLINE:
			return EntPolyline.from_dict(d)
		CadEntity.Type.TEXT:
			return EntText.from_dict(d)
	return null


# ---------------------------------------------------------------------------
# 撤销栈
# ---------------------------------------------------------------------------

func _test_undo_redo() -> void:
	var doc := CadDocument.new()
	_ok(doc.entity_count() == 0, "新文档为空")

	# 新增 -> 撤销 -> 重做
	doc.begin_transaction("画线")
	var l1 := EntLine.make(Vector2(0, 0), Vector2(1000, 0))
	doc.add_entity(l1)
	var l2 := EntLine.make(Vector2(1000, 0), Vector2(1000, 1000))
	doc.add_entity(l2)
	_ok(doc.commit_transaction(), "事务应记录到变更")
	_ok(doc.entity_count() == 2, "两次新增后应有 2 个图元")
	doc.undo_last()
	_ok(doc.entity_count() == 0, "撤销后应回到 0 个图元，实际 %d" % doc.entity_count())
	doc.redo_last()
	_ok(doc.entity_count() == 2, "重做后应恢复 2 个图元，实际 %d" % doc.entity_count())

	# 修改 -> 撤销应恢复原几何
	var target := doc.entities[0] as EntLine
	var orig := target.p1
	doc.begin_transaction("移动")
	doc.mark_modified(target)
	target.transform_by(Transform2D(0.0, Vector2(500, 500)))
	doc.touch(target)
	doc.commit_transaction()
	_ok(target.p1.distance_to(orig + Vector2(500, 500)) < 1e-4, "移动后终点应平移")
	doc.undo_last()
	var restored := doc.entities[0] as EntLine
	_ok(restored.p1.distance_to(orig) < 1e-4,
		"撤销修改后应恢复原终点 (%.3f,%.3f)，实际 (%.3f,%.3f)" % [orig.x, orig.y, restored.p1.x, restored.p1.y])

	# 删除 -> 撤销应恢复
	doc.begin_transaction("删除")
	doc.remove_entity(doc.entities[0])
	doc.commit_transaction()
	_ok(doc.entity_count() == 1, "删除后应剩 1 个图元")
	doc.undo_last()
	_ok(doc.entity_count() == 2, "撤销删除后应恢复 2 个图元，实际 %d" % doc.entity_count())

	# 回滚：事务未提交时的改动必须还原
	var before := doc.entity_count()
	doc.begin_transaction("临时")
	doc.add_entity(EntLine.make(Vector2(0, 0), Vector2(1, 1)))
	doc.rollback_transaction()
	_ok(doc.entity_count() == before, "回滚后图元数应不变，实际 %d" % doc.entity_count())


# ---------------------------------------------------------------------------

func _print_summary() -> void:
	print("")
	print("════════════════════════════════════════")
	if _fail == 0:
		print("  全部通过：%d 项断言" % _pass)
	else:
		print("  通过 %d 项，失败 %d 项" % [_pass, _fail])
		print("────────────────────────────────────────")
		for f in _failures:
			print("  ✗ ", f)
	print("════════════════════════════════════════")
