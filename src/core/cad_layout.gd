class_name CadLayout
extends RefCounted
## 图纸空间的一个布局（一张图纸）。
##
## 模型空间是 1:1 的真实尺寸，图纸空间是"一张纸"。
## 布局的作用是把模型空间的一块区域，按指定比例摆到纸上 ——
## 这样出图时线宽、字号、符号大小都按图纸毫米取值，所见即所得。
##
## 本实现每个布局只有一个视口（一个模型区域的矩形开窗）。
## 真实 CAD 支持一纸多视口（例如一张图上同时放平面图和详图），
## 那是同一套机制叠加，留待后续扩展 —— 数据结构已经能容纳（viewports 数组）。

## 视口：模型空间的一块区域映射到纸上的一个矩形
class PaperView:
	extends RefCounted
	## 在图纸上的位置与大小（图纸毫米，原点在纸张左下角）
	var paper_rect := Rect2(0, 0, 100, 100)
	## 视口中心对应的模型坐标（模型毫米）
	var model_center := Vector2.ZERO
	## 出图比例分母：1:100 时为 100
	var scale := 100.0
	## 是否锁定（锁定后不能在视口内平移模型）
	var locked := false
	## 视口边框是否打印
	var print_border := false

	func duplicate_vp() -> PaperView:
		var v := PaperView.new()
		v.paper_rect = paper_rect
		v.model_center = model_center
		v.scale = scale
		v.locked = locked
		v.print_border = print_border
		return v

	## 视口覆盖的模型区域
	func model_rect() -> Rect2:
		var half := paper_rect.size * scale * 0.5
		return Rect2(model_center - half, half * 2.0)

	## 模型坐标 -> 图纸毫米
	func model_to_paper(p: Vector2) -> Vector2:
		return paper_rect.position + paper_rect.size * 0.5 + (p - model_center) / maxf(scale, 1.0e-6)


var name := "布局1"
## 幅面名（A0~A4 或加长幅面），与 GbSheet 一致
var format := "A3"
var portrait := false
var viewports: Array = []
## 关联的图框字段（工程名称/图名/图号等），出图时写进标题栏
var title_fields: Dictionary = {}


static func make(p_name: String, p_format := "A3", p_portrait := false) -> CadLayout:
	var l := CadLayout.new()
	l.name = p_name
	l.format = p_format
	l.portrait = p_portrait
	l.viewports.append(PaperView.new())
	return l


## 纸张尺寸（图纸毫米，已按横竖式调整）
func paper_size() -> Vector2:
	var s := GbSheet.sheet_size(format)
	if s.x <= 0.0:
		s = Vector2(420.0, 297.0)
	if portrait:
		return Vector2(s.y, s.x)
	return s


## 首个视口
func main_viewport() -> PaperView:
	if viewports.is_empty():
		viewports.append(PaperView.new())
	return viewports[0] as PaperView


## 让首个视口恰好框住给定的模型区域，并按纸张可用面积取整到常用比例
func fit_model_to_paper(model_rect: Rect2, margin_mm := 10.0) -> void:
	var paper := paper_size()
	var vp := main_viewport()
	# 图框内缩（与 GbSheet.build_frame 保持一致：左 25 装订边，其余 5~10）
	var m := GbSheet.margins(format)
	var inner := Rect2(Vector2(float(m[0]), float(m[1])),
		paper - Vector2(float(m[0]) + float(m[1]), float(m[1]) * 2.0))
	# 标题栏占去右下角 180x56，视口不与它重叠
	var avail := Rect2(inner.position, inner.size - Vector2(0.0, GbSheet.TITLE_H + margin_mm))
	# 选一个不小于需求的常用比例，保证内容完整落在视口内
	var need := Vector2(maxf(model_rect.size.x, 1.0), maxf(model_rect.size.y, 1.0))
	var usable := avail.size - Vector2(margin_mm * 2.0, margin_mm * 2.0)
	var ratio := maxf(need.x / maxf(usable.x, 1.0), need.y / maxf(usable.y, 1.0))
	var scale := _snap_scale(ratio)
	vp.scale = scale
	vp.model_center = model_rect.position + model_rect.size * 0.5
	vp.paper_rect = Rect2(avail.position + Vector2(margin_mm, margin_mm),
		need / scale + Vector2(margin_mm, margin_mm) * 2.0)
	# 视口不能超出可用区域
	vp.paper_rect.size = Vector2(minf(vp.paper_rect.size.x, avail.size.x),
		minf(vp.paper_rect.size.y, avail.size.y))
	vp.paper_rect.position = avail.position + (avail.size - vp.paper_rect.size) * 0.5


## 把比例吸附到国标常用比例（GB/T 50001 第 6 章：1:1 1:2 1:5 1:10 …）
static func _snap_scale(ratio: float) -> float:
	var series := [1.0, 2.0, 2.5, 5.0, 10.0, 15.0, 20.0, 25.0, 30.0, 50.0,
		100.0, 150.0, 200.0, 300.0, 500.0, 1000.0, 2000.0]
	for s in series:
		if s >= ratio:
			return float(s)
	return 5000.0


func duplicate_layout() -> CadLayout:
	var l := CadLayout.make(name, format, portrait)
	l.viewports.clear()
	for v in viewports:
		l.viewports.append((v as PaperView).duplicate_vp())
	l.title_fields = title_fields.duplicate()
	return l


func to_dict() -> Dictionary:
	var vps := []
	for v in viewports:
		var vp := v as PaperView
		vps.append({
			"paper_rect": [vp.paper_rect.position.x, vp.paper_rect.position.y,
				vp.paper_rect.size.x, vp.paper_rect.size.y],
			"model_center": [vp.model_center.x, vp.model_center.y],
			"scale": vp.scale,
			"locked": vp.locked,
			"print_border": vp.print_border,
		})
	return {
		"name": name, "format": format, "portrait": portrait,
		"title_fields": title_fields.duplicate(), "viewports": vps,
	}


static func from_dict(d: Dictionary) -> CadLayout:
	var l := CadLayout.new()
	l.name = String(d.get("name", "布局1"))
	l.format = String(d.get("format", "A3"))
	l.portrait = bool(d.get("portrait", false))
	var tf = d.get("title_fields", {})
	if tf is Dictionary:
		l.title_fields = (tf as Dictionary).duplicate()
	l.viewports.clear()
	for vd in (d.get("viewports", []) as Array):
		var v := PaperView.new()
		var pr: Array = (vd as Dictionary).get("paper_rect", [0, 0, 100, 100])
		v.paper_rect = Rect2(float(pr[0]), float(pr[1]), float(pr[2]), float(pr[3]))
		var mc: Array = (vd as Dictionary).get("model_center", [0, 0])
		v.model_center = Vector2(float(mc[0]), float(mc[1]))
		v.scale = float((vd as Dictionary).get("scale", 100.0))
		v.locked = bool((vd as Dictionary).get("locked", false))
		v.print_border = bool((vd as Dictionary).get("print_border", false))
		l.viewports.append(v)
	if l.viewports.is_empty():
		l.viewports.append(PaperView.new())
	return l
