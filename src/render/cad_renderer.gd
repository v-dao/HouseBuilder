class_name CadRenderer
extends RefCounted
## 图元渲染器。
##
## 性能策略（实测结论：Godot 2D 的瓶颈在"提交次数"而非"线段条数"）：
##   1. 视口剔除：先用包围盒筛掉视野外的图元
##   2. 分桶：按「最终颜色 + 线宽档位」把线段归入同一个桶
##   3. 批量提交：每个桶用**一次** draw_multiline 画完
##   4. 抗锯齿交给视口的 msaa_2d，不用逐图元的 antialiased（那会打断批量）
##
## 线型（虚线/点画线）在几何展开阶段就切成实线段，因此不影响分桶。
## 线型长度定义在模型空间（mm），缩放时虚实比例不变 —— 与 CAD 行为一致。

## 折线细分的最大矢高误差（屏幕像素）。0.25px 已看不出多边形棱角。
var sagitta_px: float = 0.25
## 是否按真实线宽显示。关闭时所有线统一为 min_width_px（编辑时的常规状态）。
var show_lineweight: bool = false
## 毫米到像素的折算（96 dpi 下 1mm = 3.7795px），用于线宽显示
var px_per_mm: float = 3.779527559
var min_width_px: float = 1.0
var max_width_px: float = 12.0
## 虚线的线型周期在屏幕上小于此像素数时退化为实线，避免切出天量短段
var dash_collapse_px: float = 2.0
## 单次绘制允许的最大线段数，超出后停止累积（防止病态输入卡死）
var max_segments: int = 400000
## 全局线型比例
var ltscale: float = 1.0
## 屏幕字高小于此像素数则跳过绘制
var min_text_px: int = 5
var max_text_px: int = 600

var stats: Dictionary = {}

# 分桶：key -> PackedVector2Array（线段端点对）
var _bucket_pts: Dictionary = {}
# 分桶元数据：key -> [Color, width_px]
var _bucket_meta: Dictionary = {}
var _text_items: Array = []
var _point_items: Array = []
var _solid_items: Array = []
var _seg_count: int = 0
var _overflow := false
## 点的显示半径（屏幕像素，恒定不随缩放变化）
var point_size_px: float = 4.0


## 选择高亮的颜色
var highlight_color: Color = Color(0.35, 0.95, 0.65)
## 夹点的颜色与屏幕尺寸
var grip_color: Color = Color(0.30, 0.85, 1.0)
var grip_hot_color: Color = Color(1.0, 0.45, 0.35)
var grip_size_px: float = 3.5


## 主入口。在 CanvasItem 的 _draw() 中调用。
func draw(doc: CadDocument, view: ViewTransform, ci: CanvasItem,
		selection: Array[CadEntity] = []) -> void:
	_bucket_pts.clear()
	_bucket_meta.clear()
	_text_items.clear()
	_point_items.clear()
	_solid_items.clear()
	_seg_count = 0
	_overflow = false

	var culled := 0
	var drawn := 0
	var vr := view.visible_rect()
	var xf := view.transform()
	var sag := view.sagitta_for_pixels(sagitta_px)

	for e in doc.entities:
		if not e.visible or not doc.is_layer_visible(e.layer):
			continue
		if not vr.intersects(e.get_bbox()):
			culled += 1
			continue
		# 文字注记与几何是两条独立通道：尺寸标注同时有尺寸线（几何）
		# 和尺寸数字（文字），所以这里不能写成二选一。
		for a in e.get_annotation_texts():
			_collect_text(doc, view, e, a)

		if e.type == CadEntity.Type.POINT:
			_collect_point(doc, view, e as EntPoint)
			drawn += 1
			continue

		# 实心填充（剖切墙体等）需要真正填面，不能在线上做文章
		if e.type == CadEntity.Type.HATCH and (e as EntHatch).is_solid():
			_collect_solid(doc, view, e as EntHatch)
			drawn += 1
			continue

		var color := doc.resolve_color(e)
		if color.a > 0.001:
			var width := _resolve_width(doc, e)
			var bucket := _bucket(color, width)
			var lt := doc.get_linetype(doc.resolve_linetype(e))
			for c in e.get_curves():
				_emit_curve(doc, bucket, c, lt, e.linetype_scale, xf, sag, view.zoom)
		drawn += 1

	_flush(ci)
	_draw_solids(view, ci)
	_draw_points(doc, view, ci)
	var texts_drawn := _draw_texts(doc, view, ci)
	if not selection.is_empty():
		_draw_selection(doc, view, ci, selection)
	stats = {
		"total": doc.entity_count(),
		"culled": culled,
		"drawn": drawn,
		"segments": _seg_count,
		"buckets": _bucket_meta.size(),
		"texts": _text_items.size(),
		"texts_drawn": texts_drawn,
		"points": _point_items.size(),
		"solids": _solid_items.size(),
		"overflow": _overflow,
	}


# ---------------------------------------------------------------------------
# 分桶
# ---------------------------------------------------------------------------

## 线宽量化到 0.25px 档位，避免浮点微差产生大量几乎相同的桶
func _width_index(width_px: float) -> int:
	return int(roundf(clampf(width_px, 0.0, 63.75) * 4.0))


func _bucket(color: Color, width_px: float) -> PackedVector2Array:
	var key := (color.to_rgba32() << 8) | (_width_index(width_px) & 0xFF)
	# 注意：Dictionary.get() 在键不存在时返回 null，把 null 赋给 PackedVector2Array
	# 类型的变量会运行时报错，因此这里必须显式判存在。
	if _bucket_pts.has(key):
		return _bucket_pts[key]
	var b := PackedVector2Array()
	_bucket_pts[key] = b
	_bucket_meta[key] = [color, _width_index(width_px) * 0.25]
	return b


func _flush(ci: CanvasItem) -> void:
	for key in _bucket_pts.keys():
		var pts: PackedVector2Array = _bucket_pts[key]
		if pts.size() < 2:
			continue
		var meta: Array = _bucket_meta[key]
		var color: Color = meta[0]
		var width := maxf(float(meta[1]), min_width_px)
		ci.draw_multiline(pts, color, width)


func _resolve_width(doc: CadDocument, e: CadEntity) -> float:
	if not show_lineweight:
		return min_width_px
	var lw := doc.resolve_lineweight(e)
	if lw < 0.0:
		# 使用默认线宽：国标细实线 0.25mm
		lw = 0.25
	return clampf(lw * px_per_mm, min_width_px, max_width_px)


# ---------------------------------------------------------------------------
# 曲线展开
# ---------------------------------------------------------------------------

func _emit_curve(doc: CadDocument, bucket: PackedVector2Array, c: GeoCurve,
		lt: CadLinetype, lt_scale: float, xf: Transform2D, sag: float, zoom: float) -> void:
	if _overflow:
		return
	var poly := c.tessellate(sag)
	if poly.size() < 2:
		return

	var dashed := lt != null and not lt.is_continuous()
	if dashed:
		# 线型长度定义在模型空间，换算到屏幕看是否已经密到看不出虚实
		var cycle_mm := lt.cycle_length() * maxf(lt_scale, 1.0e-6) * ltscale
		if cycle_mm * zoom < dash_collapse_px:
			dashed = false

	if not dashed:
		_append_segments(bucket, xf * poly, c.is_closed())
		return

	# 虚线的切分必须在**模型空间**完成：线型长度是模型 mm，
	# 若先变换到屏幕再切，缩放时虚线的疏密会跟着变，与 CAD 行为不符。
	var pattern := PackedFloat64Array()
	pattern.resize(lt.pattern.size())
	for i in range(lt.pattern.size()):
		pattern[i] = lt.pattern[i] * maxf(lt_scale, 1.0e-6) * ltscale
	var model_pairs := PackedVector2Array()
	_append_dashed(model_pairs, poly, pattern, c.is_closed())
	if model_pairs.size() >= 2:
		bucket.append_array(xf * model_pairs)


func _append_segments(bucket: PackedVector2Array, pts: PackedVector2Array, closed: bool) -> void:
	if _seg_count >= max_segments:
		_overflow = true
		return
	var n := pts.size()
	for i in range(n - 1):
		bucket.append(pts[i])
		bucket.append(pts[i + 1])
	# 闭合折线补上首尾段（细分结果通常已首尾重合，故先判重）
	if closed and n > 2 and not pts[0].is_equal_approx(pts[n - 1]):
		bucket.append(pts[n - 1])
		bucket.append(pts[0])
	_seg_count += maxi(n - 1, 0)


## 在**模型空间**按「画-空」把折线切成实线段，结果以端点对追加到 out。
## 调用方随后统一做一次 xf * out 变换到屏幕。
func _append_dashed(out: PackedVector2Array, pts: PackedVector2Array,
		pattern: PackedFloat64Array, closed: bool) -> void:
	if pattern.is_empty() or _seg_count >= max_segments:
		return
	var n := pts.size()
	var limit := n if closed else n - 1
	var pi := 0
	var remain := absf(pattern[0])
	var drawing := pattern[0] >= 0.0

	for i in range(limit):
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var seg_len := a.distance_to(b)
		if seg_len <= Tol.MIN_LEN:
			continue
		var dir := (b - a) / seg_len
		var pos := 0.0
		var guard := 0
		while pos < seg_len - 1.0e-9 and guard < 4096:
			guard += 1
			var step := minf(remain, seg_len - pos)
			if drawing and step > Tol.MIN_LEN:
				out.append(a + dir * pos)
				out.append(a + dir * (pos + step))
				_seg_count += 1
			pos += step
			remain -= step
			if remain <= 1.0e-9:
				pi = (pi + 1) % pattern.size()
				remain = absf(pattern[pi])
				drawing = pattern[pi] >= 0.0
				# DXF 中长度为 0 的项表示"点"。若直接给 0 长度会导致死循环，
				# 这里给点一个极短但可见的长度。
				if remain <= 1.0e-9:
					if drawing:
						out.append(a + dir * pos)
						out.append(a + dir * minf(pos + 0.05, seg_len))
						_seg_count += 1
					pi = (pi + 1) % pattern.size()
					remain = absf(pattern[pi])
					drawing = pattern[pi] >= 0.0
		if _seg_count >= max_segments:
			_overflow = true
			return


# ---------------------------------------------------------------------------
# 文字
# ---------------------------------------------------------------------------

## 选择集高亮。单独走一遍绘制，避免污染按颜色分好的批次。
func _draw_selection(doc: CadDocument, view: ViewTransform, ci: CanvasItem,
		sel: Array[CadEntity]) -> void:
	var sag := view.sagitta_for_pixels(sagitta_px)
	var xf := view.transform()
	var acc := PackedVector2Array()
	for e in sel:
		if not e.visible or not doc.is_layer_visible(e.layer):
			continue
		for c in e.get_curves():
			var pts := xf * c.tessellate(sag)
			for i in range(pts.size() - 1):
				acc.append(pts[i])
				acc.append(pts[i + 1])
			if c.is_closed() and pts.size() > 2:
				acc.append(pts[pts.size() - 1])
				acc.append(pts[0])
	if acc.size() >= 2:
		ci.draw_multiline(acc, highlight_color, 2.0)
	# 点的选中态用高亮十字表示
	for e in sel:
		if e.type == CadEntity.Type.POINT:
			var sp := view.to_screen((e as EntPoint).position)
			ci.draw_arc(sp, 6.0, 0.0, TAU, 16, highlight_color, 1.5, true)


## 绘制选中图元的夹点。hot_index 为当前激活的夹点。
func draw_grips(view: ViewTransform, ci: CanvasItem, sel: Array[CadEntity],
		hot_entity: CadEntity = null, hot_index: int = -1) -> void:
	for e in sel:
		var pts := e.get_grips()
		var is_hot_owner := (e == hot_entity)
		for i in range(pts.size()):
			var sp := view.to_screen(pts[i])
			var col := grip_hot_color if (is_hot_owner and i == hot_index) else grip_color
			var r := grip_size_px
			ci.draw_rect(Rect2(sp - Vector2(r, r), Vector2(r, r) * 2.0), col, true)
			ci.draw_rect(Rect2(sp - Vector2(r, r), Vector2(r, r) * 2.0), Color(0.05, 0.05, 0.08), false, 1.0)


## 命中测试：返回 { entity, index } 或 null
func hit_grip(view: ViewTransform, sel: Array[CadEntity], screen_pos: Vector2,
		aperture_px := 6.0) -> Dictionary:
	for e in sel:
		var pts := e.get_grips()
		for i in range(pts.size()):
			if view.to_screen(pts[i]).distance_to(screen_pos) <= aperture_px:
				return {"entity": e, "index": i}
	return {}


## 收集实心填充的轮廓。实心填充必须在所有线之前绘制，
## 否则后画的填充会盖住先画的墙线。
func _collect_solid(doc: CadDocument, view: ViewTransform, h: EntHatch) -> void:
	var ring := h.boundary_closed()
	if ring.size() < 3:
		return
	var scr := PackedVector2Array()
	var xf := view.transform()
	for q in ring:
		scr.append(xf * q)
	_solid_items.append({"poly": scr, "color": doc.resolve_color(h), "alpha": doc.resolve_color(h).a})


func _draw_solids(_view: ViewTransform, ci: CanvasItem) -> void:
	for item in _solid_items:
		var poly: PackedVector2Array = item["poly"]
		if poly.size() < 3:
			continue
		var col: Color = item["color"]
		ci.draw_colored_polygon(poly, Color(col.r, col.g, col.b, maxf(col.a, 1.0)))


func _collect_point(doc: CadDocument, _view: ViewTransform, p: EntPoint) -> void:
	_point_items.append({"e": p, "color": doc.resolve_color(p)})


## 点用"圆 + 十字"表示，屏幕尺寸恒定。
## 恒定尺寸是刻意的：点作为定位标记，缩小时不能消失、放大时不能糊住图面。
func _draw_points(_doc: CadDocument, view: ViewTransform, ci: CanvasItem) -> void:
	if _point_items.is_empty():
		return
	var vr := view.visible_rect()
	var r := point_size_px
	for item in _point_items:
		var p: EntPoint = item["e"]
		if not vr.has_point(p.position):
			continue
		var sp := view.to_screen(p.position)
		var col: Color = item["color"]
		ci.draw_line(sp - Vector2(r, 0), sp + Vector2(r, 0), col, 1.0, true)
		ci.draw_line(sp - Vector2(0, r), sp + Vector2(0, r), col, 1.0, true)
		ci.draw_arc(sp, r * 0.75, 0.0, TAU, 16, col, 1.0, true)


## 收集一条文字注记。owner 用于取图层颜色；ann 是注记内容字典。
func _collect_text(doc: CadDocument, view: ViewTransform, owner: CadEntity, ann: Dictionary) -> void:
	var h := float(ann.get("height", 0.0))
	if h <= 0.0:
		# 字高为 0 表示跟随文字样式
		var st := doc.get_text_style(String(ann.get("style", "")))
		h = st.height if (st != null and st.height > 0.0) else 3.5
	var size_px := int(roundf(h * view.zoom))
	if size_px < min_text_px:
		return
	if size_px > max_text_px:
		size_px = max_text_px
	_text_items.append({"owner": owner, "ann": ann, "px": size_px})


## 文字在**屏幕空间**逐条提交（每条一次 draw_string）。
## 旋转文字用 draw_set_transform 建立局部坐标系，避免逐字重排。
## 返回实际绘制的条数。
func _draw_texts(doc: CadDocument, _view: ViewTransform, ci: CanvasItem) -> int:
	if _text_items.is_empty():
		return 0
	var fm := FontManager.instance()
	var vr := _view.visible_rect()
	var drawn := 0
	for item in _text_items:
		var owner: CadEntity = item["owner"]
		var ann: Dictionary = item["ann"]
		var text := String(ann.get("text", ""))
		if text == "":
			continue
		var pos_model: Vector2 = ann.get("position", Vector2.ZERO)
		if not vr.has_point(pos_model):
			continue
		var style := doc.get_text_style(String(ann.get("style", "")))
		if style == null:
			continue
		var f := fm.font_for(style)
		var px: int = item["px"]
		var pos := _view.to_screen(pos_model)
		var size := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px)
		# 文字图元要把实测尺寸回写，供拾取与包围盒使用
		if owner is EntText and not (owner as EntText).measured_valid:
			var inv := 1.0 / maxf(_view.zoom, 1.0e-9)
			(owner as EntText).set_measured_size(Vector2(size.x * inv, size.y * inv))

		var h_align := int(ann.get("h_align", EntText.HAlign.LEFT))
		var v_align := int(ann.get("v_align", EntText.VAlign.BASELINE))
		var rot := float(ann.get("rotation", 0.0))
		# 水平对正
		var dx := 0.0
		match h_align:
			EntText.HAlign.CENTER, EntText.HAlign.MIDDLE:
				dx = -size.x * 0.5
			EntText.HAlign.RIGHT:
				dx = -size.x
		# 垂直对正。局部坐标系 Y 轴向下，基线在原点，字形向上延伸，
		# 故 ascent 在局部为负、descent 为正。
		var ascent := f.get_ascent(px)
		var descent := f.get_descent(px)
		var dy := 0.0
		match v_align:
			EntText.VAlign.TOP:
				dy = ascent
			EntText.VAlign.MIDDLE:
				dy = (ascent - descent) * 0.5
			EntText.VAlign.BOTTOM:
				dy = -descent
		var color := doc.resolve_color(owner)
		# 屏幕 Y 向下，模型旋转角 theta 对应的局部系旋转为 -theta
		ci.draw_set_transform(pos, -rot, Vector2.ONE)
		ci.draw_string(f, Vector2(dx, dy), text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)
		ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		drawn += 1
	return drawn
