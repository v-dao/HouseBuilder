class_name GeoCurve
extends RefCounted
## 解析曲线基类。模型空间，单位毫米（mm），Y 轴向上（建筑制图惯例）。
##
## 这是几何内核的基本单元。实体（CadEntity）通过 get_curves() 把自己的几何
## 表达为一组 GeoCurve；渲染、捕捉、求交、编辑全部基于这层抽象，
## 而不是直接操作实体的原始字段。这样 DXF 读写、偏移、修剪等操作只需实现一次。

## 曲线类型
enum Kind { SEG, ARC, POLY, ELLIPSE, SPLINE }


func kind() -> int:
	return -1


## 按最大矢高误差细分曲线，返回折线点串（模型空间）
func tessellate(_sagitta: float) -> PackedVector2Array:
	return PackedVector2Array()


## 起点
func start_point() -> Vector2:
	return Vector2.ZERO


## 终点
func end_point() -> Vector2:
	return Vector2.ZERO


## 参数中点（按参数域 0.5，非弧长中点）
func midpoint() -> Vector2:
	return Vector2.ZERO


## 参数域取点，t 属于 [0, 1]
func point_at(_t: float) -> Vector2:
	return Vector2.ZERO


## 参数域切向（单位向量）
func tangent_at(_t: float) -> Vector2:
	return Vector2.RIGHT


## 曲线长度
func curve_length() -> float:
	return 0.0


## 包围盒
func bbox() -> Rect2:
	return Rect2()


## 闭合曲线（起终点重合且首尾相接）
func is_closed() -> bool:
	return false


## 最近点查询。返回 { point: Vector2, t: float, dist: float }
func closest_point(_p: Vector2) -> Dictionary:
	return {"point": Vector2.ZERO, "t": 0.0, "dist": INF}


## 点到曲线的最短距离
func distance_to(p: Vector2) -> float:
	return closest_point(p).get("dist", INF)


## 反转方向
func reversed() -> GeoCurve:
	return self


## 应用仿射变换，返回新曲线
func transformed(_xf: Transform2D) -> GeoCurve:
	return null


## 曲线内部的"特征点"：端点、中点、圆心、象限点等，供对象捕捉使用。
## 返回 { point: Vector2, type: int } 的数组，type 用 SnapType 常量。
func feature_points() -> Array[Dictionary]:
	return []


## 把曲线上的点追加到折线串（内部使用，避免反复分配）
func _append_polyline(_out: PackedVector2Array, _sagitta: float) -> void:
	pass


## 按矢高误差计算弦段数。sagitta 为允许的最大矢高（模型单位）。
## 矢高 s 与半径 r 的关系：s = r * (1 - cos(halfAngle))，故
## halfAngle = acos(1 - s/r)，段数 n = ceil(sweep / (2 * halfAngle))。
static func arc_segment_count(radius: float, sweep: float, sagitta: float) -> int:
	if radius <= Tol.MIN_RADIUS:
		return 1
	if sagitta <= 0.0:
		sagitta = 0.01
	# 矢高不小于半径时整段退化，最少 2 段保证形状可辨
	var ratio := 1.0 - sagitta / radius
	if ratio <= -1.0:
		return 2
	var half := acos(clampf(ratio, -1.0, 1.0))
	if half <= 1.0e-9:
		return 2
	var n := int(ceilf(absf(sweep) / (2.0 * half)))
	return maxi(n, 2)
