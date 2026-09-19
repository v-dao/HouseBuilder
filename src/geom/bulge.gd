class_name Bulge
extends RefCounted
## 圆弧与 bulge 参数的双向转换。
##
## bulge 是 DXF 中 LWPOLYLINE/POLYLINE 表达圆弧段的方式：
##   bulge = tan(theta / 4)，theta 为该段的圆心角（含符号）
##   bulge > 0 表示从起点到终点逆时针；bulge = 0 表示直线；bulge = 1 表示半圆
##
## 重要几何结论（已推导验证，反直觉，勿凭记忆改动）：
##   设弦 p0->p1，d = |p1-p0|/2，left_perp 为弦方向逆时针旋转 90°，
##   则圆心 = chord_mid + left_perp * (d / tan(theta/2))
##   当 bulge > 0（逆时针）时，圆弧位于弦的【右侧】，而非左侧。
##
## 验证：p0=(0,0), p1=(2,0), bulge=1 -> theta=PI, d=1, tan(PI/2)=inf,
##   圆心 = (1,0)；逆时针从 180° 扫到 360°，经过 270° 即点 (1,-1)，在弦下方。正确。

## 圆心角 -> bulge
static func from_angle(theta: float) -> float:
	return tan(theta * 0.25)


## bulge -> 圆心角
static func to_angle(b: float) -> float:
	return 4.0 * atan(b)


## 判断该 bulge 是否退化为直线
static func is_straight(b: float) -> bool:
	return absf(b) <= 1.0e-12


## 由圆弧反算 bulge（供 DXF 导出使用）
static func from_arc(arc: GeoArc) -> float:
	var theta := arc.sweep()
	if not arc.ccw:
		theta = -theta
	return from_angle(theta)


## 由两端点与 bulge 构造曲线（GeoSeg 或 GeoArc）。
## 退化情况（弦长为 0、bulge 为 0、或半径异常）一律返回直线段。
static func span_to_curve(p0: Vector2, p1: Vector2, b: float) -> GeoCurve:
	if is_straight(b):
		return GeoSeg.make(p0, p1)
	var chord := p1 - p0
	var chord_len := chord.length()
	if chord_len <= Tol.MIN_LEN:
		return GeoSeg.make(p0, p1)

	var theta := to_angle(b)
	var half := theta * 0.5
	var sin_half := sin(half)
	# |sin(theta/2)| 过小 => 半径趋于无穷，按直线处理
	if absf(sin_half) <= 1.0e-9:
		return GeoSeg.make(p0, p1)

	var radius := chord_len / (2.0 * absf(sin_half))
	if radius <= Tol.MIN_RADIUS:
		return GeoSeg.make(p0, p1)

	var mid := (p0 + p1) * 0.5
	var d := chord_len * 0.5
	var tan_half := tan(half)
	# |theta| 接近 PI 时 tan 趋于无穷（半圆），圆心即弦中点
	var apothem := 0.0
	if absf(tan_half) > 1.0e-9:
		apothem = d / tan_half

	var dir := chord / chord_len
	var left_perp := Vector2(-dir.y, dir.x)
	var arc_center := mid + left_perp * apothem

	var a0 := (p0 - arc_center).angle()
	var a1 := (p1 - arc_center).angle()
	# bulge 的符号即扫掠方向：正为逆时针。
	# a0/a1 各自归一化到 (-PI, PI]，fposmod 会自动处理跨 0 的绕行，
	# 因此 GeoArc.sweep() 得到的扫掠角必然等于 |theta|，无需额外修正。
	return GeoArc.make(arc_center, radius, a0, a1, b > 0.0)
