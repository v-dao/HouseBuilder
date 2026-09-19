class_name DemoDrawing
extends RefCounted
## 示例图纸生成器。
##
## 用途有两个：
##   1. 新用户首次打开软件时能立刻看到"这软件画出来的图长什么样"
##   2. 作为渲染管线的验收素材 —— 一张图里覆盖了国标的各种线宽、线型、
##      图形元素与长仿宋文字，出问题一眼就能看出
##
## 内容按 GB/T 50001 的线宽体系组织：
##   粗实线 b(1.0) 墙体轮廓 / 中粗 0.7b 次要轮廓 / 中实线 0.5b 尺寸符号 /
##   细实线 0.25b 图例填充 / 细单点长画线 0.25b 定位轴线


## 构建一张演示用的一层平面图（约 8.4m × 6.0m）
static func build(doc: CadDocument) -> void:
	_setup_layers(doc)
	var ax := _layer(doc, "轴线", Color(0.55, 0.62, 0.72), "CENTER", 0.25)
	var wall := _layer(doc, "墙体", Color(0.95, 0.95, 0.92), "CONTINUOUS", 1.0)
	var win := _layer(doc, "门窗", Color(0.55, 0.80, 1.0), "CONTINUOUS", 0.7)
	var dim := _layer(doc, "尺寸标注", Color(1.0, 0.82, 0.35), "CONTINUOUS", 0.5)
	var hatch := _layer(doc, "图例填充", Color(0.45, 0.48, 0.55), "CONTINUOUS", 0.25)
	var txt := _layer(doc, "文字", Color(0.85, 0.95, 0.85), "CONTINUOUS", 0.25)
	var stair := _layer(doc, "楼梯", Color(0.60, 0.85, 0.75), "CONTINUOUS", 0.7)

	# --- 轴网 2 跨 × 2 跨，符合 GB/T 50002 的常用开间进深 ---
	var xs := [0.0, 3600.0, 7800.0]
	var ys := [0.0, 3000.0, 6000.0]
	for i in range(xs.size()):
		var e := EntLine.make(Vector2(xs[i], -900.0), Vector2(xs[i], 6900.0))
		_put(e, ax)
		doc.add_entity(e, false)
		# 轴号圆圈（直径 8~10mm，取 100mm 适应本图比例）
		var c := EntCircle.make(Vector2(xs[i], 7200.0), 220.0)
		_put(c, ax)
		doc.add_entity(c, false)
		var t := EntText.make(Vector2(xs[i], 7130.0), str(i + 1), 350.0)
		t.text_style = "图名_7"
		t.h_align = EntText.HAlign.CENTER
		_put(t, ax)
		doc.add_entity(t, false)
	for j in range(ys.size()):
		var e2 := EntLine.make(Vector2(-900.0, ys[j]), Vector2(8700.0, ys[j]))
		_put(e2, ax)
		doc.add_entity(e2, false)
		var c2 := EntCircle.make(Vector2(-1200.0, ys[j]), 220.0)
		_put(c2, ax)
		doc.add_entity(c2, false)
		var t2 := EntText.make(Vector2(-1200.0, ys[j] - 70.0), String.chr(65 + j), 350.0)
		t2.text_style = "图名_7"
		t2.h_align = EntText.HAlign.CENTER
		_put(t2, ax)
		doc.add_entity(t2, false)

	# --- 双线墙：外墙 240 厚、内墙 120 厚，用闭合多段线画墙体轮廓 ---
	var outer := _rect_poly(-120.0, -120.0, 7920.0, 6120.0)
	_add_poly(doc, wall, outer, true)
	# 内墙：L 形隔墙
	var inner := GeoPoly.make(PackedVector2Array([
		Vector2(3600.0 - 60.0, -120.0),
		Vector2(3600.0 + 60.0, -120.0),
		Vector2(3600.0 + 60.0, 3000.0),
		Vector2(3600.0 - 60.0, 3000.0),
	]), PackedFloat64Array(), true)
	_add_poly(doc, wall, inner, true)
	var inner2 := GeoPoly.make(PackedVector2Array([
		Vector2(-120.0, 3000.0 - 60.0),
		Vector2(3600.0, 3000.0 - 60.0),
		Vector2(3600.0, 3000.0 + 60.0),
		Vector2(-120.0, 3000.0 + 60.0),
	]), PackedFloat64Array(), true)
	_add_poly(doc, wall, inner2, true)

	# --- 门扇与开启弧（国标画法：门扇线 + 90° 开启弧）---
	_add_door(doc, win, Vector2(1800.0, -120.0), 900.0, 0.0, true)
	_add_door(doc, win, Vector2(3600.0, 1800.0), 800.0, PI * 0.5, false)

	# --- 窗：墙上三条平行细线 ---
	_add_window(doc, win, -120.0, 1500.0, 0.0, 1500.0, 240.0)
	_add_window(doc, win, 7920.0, 1200.0, 0.0, 1800.0, 240.0)

	# --- 楼梯间：第二跨下侧做楼梯间，画双跑楼梯的踏步线 ---
	# 楼梯间与卧室之间的分隔墙（120 厚）
	var stair_wall := GeoPoly.make(PackedVector2Array([
		Vector2(3720.0, 1500.0 - 60.0),
		Vector2(7800.0, 1500.0 - 60.0),
		Vector2(7800.0, 1500.0 + 60.0),
		Vector2(3720.0, 1500.0 + 60.0),
	]), PackedFloat64Array(), true)
	_add_poly(doc, wall, stair_wall, true)
	# 两跑踏步：上行梯段 9 级，踏步宽 260，梯段宽 1100
	var tread := 260.0
	var st_x := 3900.0
	for run in range(2):
		var y0 := 180.0 + float(run) * 1380.0
		for i in range(9):
			var y := y0 + float(i) * tread
			var e3 := EntLine.make(Vector2(st_x, y), Vector2(st_x + 1100.0, y))
			_put(e3, stair)
			doc.add_entity(e3, false)
		# 梯段分隔线
		var mid := EntLine.make(Vector2(st_x + 1100.0, y0), Vector2(st_x + 1100.0, y0 + 8.0 * tread))
		_put(mid, stair)
		doc.add_entity(mid, false)

	# --- 图例填充：45° 素线。放在图面外的图例框里，
	#     不压住房间名（GB/T 50001 附录的建筑材料图例画法基础）---
	_add_hatch_legend(doc, hatch, txt)

	# --- 尺寸标注：三道尺寸线（门窗定位 / 轴线 / 总尺寸）---
	_add_dim_chain(doc, dim, txt, xs, -900.0)
	_add_dim_chain(doc, dim, txt, [0.0, 7800.0], -1500.0)
	_add_dim_chain(doc, dim, txt, [-120.0, 7920.0], -2100.0)

	# --- 房间名与面积 ---
	_add_room(doc, txt, Vector2(1740.0, 1440.0), "客厅", "22.2 m²")
	_add_room(doc, txt, Vector2(5940.0, 2300.0), "卧室", "7.3 m²")
	_add_room(doc, txt, Vector2(1740.0, 4380.0), "厨房", "9.8 m²")
	_add_room(doc, txt, Vector2(5940.0, 4380.0), "卫生间", "6.6 m²")

	# --- 图名与比例 ---
	var title := EntText.make(Vector2(3000.0, -3600.0), "一层平面图  1:100", 700.0)
	title.text_style = "图名_7"
	title.h_align = EntText.HAlign.CENTER
	_put(title, txt)
	doc.add_entity(title, false)

	var note := EntText.make(Vector2(3000.0, -4500.0), "±0.000  室内地坪  墙体 240 厚烧结普通砖", 350.0)
	note.text_style = "仿宋_3.5"
	note.h_align = EntText.HAlign.CENTER
	_put(note, txt)
	doc.add_entity(note, false)

	doc.commit_transaction()


## ACI 颜色索引 -> 观察色。国内建筑图按"图层颜色决定打印线宽"的习惯组织，
## 这里给每个图层配一个便于在深底上区分的观察色，ACI 值同时用于 DXF 往返。
const LAYER_COLORS := {
	"轴线": [Color(0.55, 0.62, 0.72), 8],
	"墙体": [Color(0.95, 0.95, 0.92), 7],
	"柱": [Color(1.0, 0.85, 0.75), 30],
	"门窗": [Color(0.55, 0.80, 1.0), 4],
	"楼梯": [Color(0.60, 0.85, 0.75), 3],
	"尺寸标注": [Color(1.0, 0.82, 0.35), 2],
	"图例填充": [Color(0.45, 0.48, 0.55), 8],
	"家具": [Color(0.70, 0.62, 0.85), 6],
	"文字": [Color(0.85, 0.95, 0.85), 3],
	"图框": [Color(0.80, 0.80, 0.85), 7],
}


## 按 GB/T 50001 的线宽组建立图层。
## 线宽组由基本线宽 b 生成：b / 0.7b / 0.5b / 0.25b。
## 1:100 的平面图取 b = 1.0（详见 GbLineweight 的说明）。
static func _setup_layers(doc: CadDocument) -> void:
	var b := GbLineweight.b_for_plot_scale(doc.plot_scale)
	for row in GbLineweight.default_layer_map():
		var name := String(row[0])
		var linetype := String(row[1])
		var usage := String(row[2])
		var desc := String(row[3])
		var entry = LAYER_COLORS.get(name)
		var color: Color = entry[0] if entry != null else Color.WHITE
		var aci: int = int(entry[1]) if entry != null else 7
		var w := GbLineweight.width_for(usage, b)
		doc.layers[name] = CadLayer.make(name, color, aci, linetype, w, desc)


static func _layer(doc: CadDocument, name: String, _c: Color, _lt: String, _lw: float) -> String:
	doc.ensure_layer(name)
	return name


static func _put(e: CadEntity, layer: String) -> void:
	e.layer = layer
	e.aci = 256
	e.linetype = "BYLAYER"
	e.lineweight = CadLayer.LW_BYLAYER


static func _rect_poly(x: float, y: float, w: float, h: float) -> GeoPoly:
	return GeoPoly.make(PackedVector2Array([
		Vector2(x, y), Vector2(x + w, y), Vector2(x + w, y + h), Vector2(x, y + h),
	]), PackedFloat64Array(), true)


static func _add_poly(doc: CadDocument, layer: String, p: GeoPoly, closed: bool) -> void:
	var e := EntPolyline.make_from_geo(GeoPoly.make(p.points, p.bulges, closed))
	_put(e, layer)
	doc.add_entity(e, false)


## 门：门扇线（垂直于墙）+ 90° 开启弧。国标中门开启弧用细实线。
static func _add_door(doc: CadDocument, layer: String, base: Vector2, width: float, rot: float, _swing_left: bool) -> void:
	var xf := Transform2D(rot, base)
	var leaf := EntLine.make(xf * Vector2(0, 0), xf * Vector2(0, width))
	_put(leaf, layer)
	doc.add_entity(leaf, false)
	var arc := EntArc.make(base, width, rot + PI * 0.5, rot + PI)
	_put(arc, layer)
	doc.add_entity(arc, false)


## 窗：国标用三条平行细线表示（窗台线 + 玻璃线 + 窗顶线）
static func _add_window(doc: CadDocument, layer: String, x: float, y: float, _rot: float, width: float, wall: float) -> void:
	for k in [-1.0, 0.0, 1.0]:
		var off := Vector2(k * wall * 0.5 * 0.72, 0.0)
		var e := EntLine.make(Vector2(x, y) + off, Vector2(x, y + width) + off)
		_put(e, layer)
		doc.add_entity(e, false)


## 45° 素线填充。真实的关联填充（拾取边界自动生成）在 P3 实现，
## 这里先用直接生成的线段验证渲染质量。
static func _add_hatch_lines(doc: CadDocument, layer: String, r: Rect2, spacing: float, angle: float) -> void:
	if spacing <= 0.0:
		return
	var dir := Vector2(cos(angle), sin(angle))
	var nrm := Vector2(-dir.y, dir.x)
	# 以矩形中心为基准，沿法向铺线
	var c := r.position + r.size * 0.5
	var half_diag := r.size.length() * 0.5
	var count := int(half_diag * 2.0 / spacing) + 2
	var segs := PackedVector2Array()
	for i in range(count):
		var off := (float(i) - float(count) * 0.5) * spacing
		var base := c + nrm * off
		var a := base - dir * half_diag
		var b := base + dir * half_diag
		var clipped := _clip_seg_rect(a, b, r)
		if clipped.size() == 2:
			segs.append(clipped[0])
			segs.append(clipped[1])
	if segs.is_empty():
		return
	# 用一条多段线承载所有填充线段（渲染器会自动分桶批量提交）
	var e := EntPolyline.make(segs, PackedFloat64Array(), false)
	_put(e, layer)
	doc.add_entity(e, false)


## 直线段对矩形的裁剪（Liang-Barsky）
static func _clip_seg_rect(a: Vector2, b: Vector2, r: Rect2) -> PackedVector2Array:
	var dx := b.x - a.x
	var dy := b.y - a.y
	var t0 := 0.0
	var t1 := 1.0
	var p := PackedFloat64Array([-dx, dx, -dy, dy])
	var q := PackedFloat64Array([a.x - r.position.x, r.position.x + r.size.x - a.x, a.y - r.position.y, r.position.y + r.size.y - a.y])
	for i in range(4):
		if absf(p[i]) <= 1.0e-12:
			if q[i] < 0.0:
				return PackedVector2Array()
		else:
			var t := q[i] / p[i]
			if p[i] < 0.0:
				t0 = maxf(t0, t)
			else:
				t1 = minf(t1, t)
	if t0 > t1:
		return PackedVector2Array()
	return PackedVector2Array([a + Vector2(dx, dy) * t0, a + Vector2(dx, dy) * t1])


## 尺寸链：尺寸界线 + 尺寸线 + 45° 斜短线起止符号 + 尺寸数字
## 完全按 GB/T 50001 第 11 章：界线超出尺寸线 2.5、起止符号 45° 长 2.5、数字在尺寸线上方居中
static func _add_dim_chain(doc: CadDocument, dim_layer: String, txt_layer: String,
		stops: Array, y: float) -> void:
	if stops.size() < 2:
		return
	# 尺寸线
	var dl := EntLine.make(Vector2(stops[0], y), Vector2(stops[stops.size() - 1], y))
	_put(dl, dim_layer)
	doc.add_entity(dl, false)
	for i in range(stops.size()):
		# 尺寸界线（自图形轮廓线引出，超出尺寸线 2.5×比例）
		var ext := EntLine.make(Vector2(stops[i], y - 180.0), Vector2(stops[i], y + 420.0))
		_put(ext, dim_layer)
		doc.add_entity(ext, false)
		# 起止符号：45° 中粗斜短线
		var tick := EntLine.make(Vector2(stops[i] - 180.0, y - 180.0), Vector2(stops[i] + 180.0, y + 180.0))
		_put(tick, dim_layer)
		doc.add_entity(tick, false)
		if i < stops.size() - 1:
			var mid := (float(stops[i]) + float(stops[i + 1])) * 0.5
			var label := "%.0f" % absf(float(stops[i + 1]) - float(stops[i]))
			var t := EntText.make(Vector2(mid, y + 60.0), label, 240.0)
			t.text_style = "标注_2.5"
			t.h_align = EntText.HAlign.CENTER
			_put(t, txt_layer)
			doc.add_entity(t, false)


## 图例框：在图纸左下角画一个小方框并填充 45° 素线，
## 顺便验证"填充线不压文字"的图面组织
static func _add_hatch_legend(doc: CadDocument, hatch_layer: String, txt_layer: String) -> void:
	var box := Rect2(-4600.0, -1400.0, 1400.0, 1400.0)
	_add_poly(doc, hatch_layer, _rect_poly(box.position.x, box.position.y, box.size.x, box.size.y), true)
	_add_hatch_lines(doc, hatch_layer, box, 200.0, PI * 0.25)
	var t := EntText.make(Vector2(box.position.x + box.size.x * 0.5, box.position.y + box.size.y + 260.0),
		"素土夯实", 320.0)
	t.text_style = "仿宋_3.5"
	t.h_align = EntText.HAlign.CENTER
	_put(t, txt_layer)
	doc.add_entity(t, false)


static func _add_room(doc: CadDocument, layer: String, pos: Vector2, name: String, area: String) -> void:
	var t := EntText.make(pos, name, 350.0)
	t.text_style = "房间名_5"
	t.h_align = EntText.HAlign.CENTER
	_put(t, layer)
	doc.add_entity(t, false)
	var a := EntText.make(pos - Vector2(0, 420.0), area, 250.0)
	a.text_style = "标注_2.5"
	a.h_align = EntText.HAlign.CENTER
	_put(a, layer)
	doc.add_entity(a, false)
