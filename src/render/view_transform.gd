class_name ViewTransform
extends RefCounted
## 模型空间（mm，Y 轴向上）与屏幕空间（像素，Y 轴向下）之间的双向变换。
##
## 建筑制图用笛卡尔坐标（Y 向上），而屏幕 Y 向下，因此变换包含一次 Y 轴翻转。
## 所有与"屏幕像素"相关的量（拾取容差、矢高误差、线宽显示）都由此处换算，
## 保证在不同缩放级别下行为一致。

## 缩放：每毫米对应多少屏幕像素
var zoom: float = 1.0
## 视口中心所对应的模型坐标
var center: Vector2 = Vector2.ZERO
## 视口尺寸（像素）
var view_size: Vector2 = Vector2(1600, 900)

## 缩放上下限：下限保证 100 米跨度的图仍可见，上限允许看清 1 微米级细节
const ZOOM_MIN := 1.0e-4
const ZOOM_MAX := 5.0e3


func set_view_size(s: Vector2) -> void:
	if s.x > 0.0 and s.y > 0.0:
		view_size = s


## 模型 -> 屏幕
func to_screen(p: Vector2) -> Vector2:
	return Vector2((p.x - center.x) * zoom, -(p.y - center.y) * zoom) + view_size * 0.5


## 屏幕 -> 模型
func to_model(p: Vector2) -> Vector2:
	var d := p - view_size * 0.5
	return Vector2(d.x / zoom, -d.y / zoom) + center


## 屏幕向量 -> 模型向量（不含平移）
func vec_to_model(v: Vector2) -> Vector2:
	return Vector2(v.x / zoom, -v.y / zoom)


## 模型向量 -> 屏幕向量
func vec_to_screen(v: Vector2) -> Vector2:
	return Vector2(v.x * zoom, -v.y * zoom)


## 完整变换矩阵。与 to_screen 等价，供批量几何变换使用（一次变换整串点）。
func transform() -> Transform2D:
	return Transform2D(
		Vector2(zoom, 0.0),
		Vector2(0.0, -zoom),
		view_size * 0.5 - Vector2(zoom * center.x, -zoom * center.y)
	)


## 可见区域（模型空间）
func visible_rect() -> Rect2:
	var half := Vector2(view_size.x / zoom, view_size.y / zoom) * 0.5
	return Rect2(center - half, half * 2.0)


## 当前缩放下，一个屏幕像素对应多少模型单位。用于矢高与拾取容差的换算。
func mm_per_pixel() -> float:
	return 1.0 / zoom


## 把屏幕像素误差换算成模型空间的矢高阈值
func sagitta_for_pixels(px: float) -> float:
	return px / zoom


## 把屏幕像素容差换算成模型空间的距离容差
func tolerance_for_pixels(px: float) -> float:
	return px / zoom


# ---------------------------------------------------------------------------
# 视图操作
# ---------------------------------------------------------------------------

## 以某个屏幕位置为锚点缩放。锚点下的模型坐标在缩放前后保持不变，
## 这是"滚轮缩放跟随光标"的核心。
func zoom_at(screen_pos: Vector2, factor: float) -> void:
	var anchor_model := to_model(screen_pos)
	zoom = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	# 解出新的中心，使 to_screen(anchor_model) == screen_pos
	var d := screen_pos - view_size * 0.5
	center = anchor_model - Vector2(d.x / zoom, -d.y / zoom)


## 按屏幕像素平移视图
func pan_by_pixels(delta_px: Vector2) -> void:
	center -= Vector2(delta_px.x / zoom, -delta_px.y / zoom)


## 平移视图（模型单位）
func pan_by_model(delta: Vector2) -> void:
	center += delta


## 缩放到刚好容纳给定矩形
func zoom_to_fit(r: Rect2, margin_ratio := 0.05) -> void:
	if r.size.x <= 0.0 and r.size.y <= 0.0:
		return
	center = r.position + r.size * 0.5
	var need_x := view_size.x * (1.0 - margin_ratio * 2.0)
	var need_y := view_size.y * (1.0 - margin_ratio * 2.0)
	var zx := need_x / maxf(r.size.x, Tol.MIN_LEN)
	var zy := need_y / maxf(r.size.y, Tol.MIN_LEN)
	zoom = clampf(minf(zx, zy), ZOOM_MIN, ZOOM_MAX)


func reset() -> void:
	zoom = 1.0
	center = Vector2.ZERO


## 屏幕上一个像素对应的模型长度，用于状态栏显示
func pixel_size_label() -> String:
	var mm := mm_per_pixel()
	if mm < 0.001:
		return "%.1f μm/px" % (mm * 1000.0)
	if mm < 1.0:
		return "%.3f mm/px" % mm
	return "%.2f mm/px" % mm


## 估算等效出图比例（假定屏幕 96dpi，1mm = 3.7795px）
func approx_plot_scale() -> String:
	var px_per_mm_screen := 3.779527559
	var ratio := (1.0 / zoom) / (1.0 / px_per_mm_screen)
	# zoom 是 px/mm，等效比例 = 纸上 1mm 代表多少模型 mm
	var denom := zoom * (1.0 / px_per_mm_screen)
	if denom <= 0.0:
		return "—"
	var r := 1.0 / denom
	if r >= 1.0:
		return "1:%.0f" % r
	return "%.1f:1" % (1.0 / r)
