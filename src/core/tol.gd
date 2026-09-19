class_name Tol
extends RefCounted
## 全局容差与几何比较工具。
##
## 模型空间单位为毫米（mm），这是建筑制图的自然单位（轴线 3600、墙厚 240 等）。
##
## 精度说明：
## Godot 的 Vector2 内部为 32 位浮点，在 30000mm（30m 跨度）处的最小可分辨
## 步长约 0.002mm。因此绝对点容差取 1e-3 mm（1 微米）——比任何制图精度
## （通常 1mm）小三个数量级，不会掩盖真实误差，同时也不会被浮点噪声触发。
## 涉及长链累加（求交、偏移、拟合）的标量运算一律使用 GDScript 的 float
## （内部为 64 位双精度）以抑制误差累积。

## 点重合容差 (mm)
const POINT: float = 1.0e-3
## 距离 / 长度容差 (mm)
const DIST: float = 1.0e-3
## 角度容差 (rad)
const ANGLE: float = 1.0e-6
## 曲线参数域容差
const PARAM: float = 1.0e-6
## 最短可辨识线段长度 (mm)；短于此长度视为退化
const MIN_LEN: float = 1.0e-3
## 圆半径下限 (mm)
const MIN_RADIUS: float = 1.0e-3

# ---------------------------------------------------------------------------
# 标量比较
# ---------------------------------------------------------------------------

static func eq(a: float, b: float, t: float = DIST) -> bool:
	return absf(a - b) <= t


static func ne(a: float, b: float, t: float = DIST) -> bool:
	return absf(a - b) > t


static func lt(a: float, b: float, t: float = DIST) -> bool:
	return a < b - t


static func gt(a: float, b: float, t: float = DIST) -> bool:
	return a > b + t


static func le(a: float, b: float, t: float = DIST) -> bool:
	return a <= b + t


static func ge(a: float, b: float, t: float = DIST) -> bool:
	return a >= b - t


static func is_zero(f: float, t: float = DIST) -> bool:
	return absf(f) <= t


# ---------------------------------------------------------------------------
# 点比较
# ---------------------------------------------------------------------------

static func pt_eq(a: Vector2, b: Vector2, t: float = POINT) -> bool:
	return absf(a.x - b.x) <= t and absf(a.y - b.y) <= t


static func pt_eq_sq(a: Vector2, b: Vector2, t: float = POINT) -> bool:
	return a.distance_squared_to(b) <= t * t


static func pt_zero(v: Vector2, t: float = DIST) -> bool:
	return absf(v.x) <= t and absf(v.y) <= t


# ---------------------------------------------------------------------------
# 角度
# ---------------------------------------------------------------------------

## 归一化到 [0, TAU)
static func norm_angle(a: float) -> float:
	return fposmod(a, TAU)


## 归一化到 (-PI, PI]
static func norm_angle_signed(a: float) -> float:
	return fposmod(a + PI, TAU) - PI


## 从 a0 逆时针到 a1 的扫掠角，落在 [0, TAU)
static func ccw_sweep(a0: float, a1: float) -> float:
	var s := norm_angle(a1 - a0)
	if is_zero(s, ANGLE):
		s = 0.0
	return s


## 判断角度 a 是否落在逆时针区间 [a0, a1] 内。
## 当区间扫掠角小于角度容差时视为整圆（起止点重合）。
static func angle_in_ccw(a: float, a0: float, a1: float, t: float = ANGLE) -> bool:
	var sweep := norm_angle(a1 - a0)
	if sweep <= t:
		sweep = TAU
	var d := norm_angle(a - a0)
	return d <= sweep + t


## 判断角度 a 是否落在顺时针区间 [a0 -> a1] 内
static func angle_in_cw(a: float, a0: float, a1: float, t: float = ANGLE) -> bool:
	return angle_in_ccw(-a, -a0, -a1, t)


# ---------------------------------------------------------------------------
# 数值安全
# ---------------------------------------------------------------------------

## 安全除法：分母接近 0 时返回 fallback
static func safe_div(a: float, b: float, fallback: float = 0.0) -> float:
	if absf(b) <= 1.0e-15:
		return fallback
	return a / b


## 夹取到 [lo, hi]
static func clampf_safe(v: float, lo: float, hi: float) -> float:
	if lo > hi:
		return lo
	return clampf(v, lo, hi)


## 判定三角形面积对应的叉积是否退化
static func cross_degenerate(ax: float, ay: float, bx: float, by: float) -> bool:
	return absf(ax * by - ay * bx) <= 1.0e-12
