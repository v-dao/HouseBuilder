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
## 图纸空间视口的裁剪矩形（屏幕坐标）。enabled 为假时不裁剪。
## 没有裁剪的话，视口外的模型内容会溢出到图纸的其他区域上。
var clip_enabled := false
var clip_rect := Rect2()

## 屏幕字高小于此像素数则跳过绘制
var min_text_px: int = 5
var max_text_px: int = 600

var stats: Dictionary = {}

# 分桶：key -> PackedVector2Array（线段端点对）
var _bucket_pts: Dictionary = {}
# 分桶元数据：key -> [Color, width_px]
var _bucket_meta: Dictionary = {}
## 模型空间几何缓存。
## 键为「文档版本 + 缩放档位 + 线宽模式 + 线型比例」，命中时跳过整个图元遍历。
## 值仍是分桶的点串，但点是**模型坐标**。
##
## 为什么要这样缓存：原先每帧要为每个图元做可见性/颜色/线宽/线型的解析，
## 再把点逐个变换到屏幕 —— 十万图元下就是每帧上百万次 GDScript 操作。
## 改成缓存模型坐标后，每帧只剩「每个桶做一次 C++ 数组变换」，
## 分桶通常只有几个，于是每帧的 GDScript 工作量与图元数无关。
var _geo_cache_key: String = ""
var _geo_valid := false

## 每帧构建一次的图层解析缓存：
## 图层名 -> {visible, color, width, linetype, bucket}
## 没有它的话，每个图元都要做四五次字典查找（可见性/颜色/线宽/线型），
## 十万图元下这些查找本身就是主要开销之一。
var _layer_cache: Dictionary = {}
var _text_items: Array = []
var _point_items: Array = []
var _solid_items: Array = []
var _seg_count: int = 0
var _overflow := false
## 上次构建几何时的可见图元数，供缓存命中时的统计使用
var _cached_drawn: int = 0

## 辅助图元的清单：文字、点、实心填充。
##
## 它们与普通几何的区别：像素尺寸与颜色**每帧都要按当前视图重解析**，
## 而"哪些图元是文字/点/实心填充"只随文档变化。
## 因此缓存清单（按文档版本），每帧只重解析尺寸与颜色。
##
## 教训：这些图元曾被放进"缓存命中就跳过"的图元遍历里，
## 结果只有缩放（缓存重建）时文字才出现 —— 典型的缓存边界划错。
var _aux_text: Array = []
var _aux_points: Array = []
var _aux_solids: Array = []
var _aux_revision := -1
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
	# 辅助图元每帧重建：清单按文档缓存，尺寸与颜色按当前视图重解析。
	# 必须在几何缓存判断**之前**做 —— 它们与几何缓存无关。
	_build_aux_lists(doc)
	_text_items.clear()
	_point_items.clear()
	_solid_items.clear()
	for te in _aux_text:
		for a in (te as CadEntity).get_annotation_texts():
			_collect_text(doc, view, te, a)
	for pe in _aux_points:
		_collect_point(doc, view, pe as EntPoint)
	for he in _aux_solids:
		_collect_solid(doc, view, he as EntHatch)
	# 注意：_seg_count / _overflow / _cached_drawn 只在**重建**时清。
	# 放在这里会让缓存命中时读到被清零的值（统计全部显示 0）。

	var culled := 0
	var drawn := 0
	var wall_count := 0
	var vr := view.visible_rect()
	var xf := view.transform()
	var sag := view.sagitta_for_pixels(sagitta_px)

	# 几何缓存命中：图元遍历、颜色解析、圆弧细分全部跳过，
	# 直接进入下面的分桶提交阶段。
	var want_key := _geometry_key(doc, view)
	if _geo_valid and want_key == _geo_cache_key:
		_flush(ci, xf)
		var sd0 := _draw_solids(view, ci)
		var td0 := _draw_texts(doc, view, ci)
		stats = {
			"total": doc.entity_count(), "culled": 0, "drawn": _cached_drawn,
			"segments": _seg_count, "buckets": _bucket_meta.size(),
			"texts": _text_items.size(), "texts_drawn": td0,
			"points": _point_items.size(), "solids": sd0,
			"overflow": _overflow, "cache": "hit",
		}
		return

	_geo_cache_key = want_key
	_geo_valid = true
	_bucket_pts.clear()
	_bucket_meta.clear()
	_layer_cache.clear()
	_seg_count = 0
	_overflow = false
	_cached_drawn = 0

	for e in doc.entities:
		if not e.visible:
			continue
		var lc: Dictionary = _layer_info(doc, e.layer)
		if not bool(lc["visible"]):
			continue
		if not vr.intersects(e.get_bbox()):
			culled += 1
			continue
		# 文字注记由辅助通道处理（见 draw 开头），这里不再收集。
		# 注意：尺寸标注同时有尺寸线（几何）和尺寸数字（文字），
		# 所以它既要走这里入桶，也要出现在辅助清单里。
		if e.type == CadEntity.Type.POINT:
			drawn += 1
			continue

		# 墙体：不走逐墙绘制，改由下方的并集轮廓统一出图，
		# 否则两墙相接处会露出对方的端边与内线
		if e.type == CadEntity.Type.WALL:
			wall_count += 1
			continue

		# 块引用：块内图元可能各有图层与颜色（随块 BYBLOCK），
		# 不能整体当一个颜色画，必须逐个解析
		if e.type == CadEntity.Type.INSERT:
			_emit_insert(doc, view, e as EntInsert, xf, sag)
			drawn += 1
			continue

		# 实心填充已由辅助通道处理，这里跳过（它不产生线几何）
		if e.type == CadEntity.Type.HATCH and (e as EntHatch).is_solid():
			drawn += 1
			continue

		# 图元自身指定了颜色或线型时才走逐图元解析，
		# 否则直接用图层缓存的结果 —— 绝大多数图元都是随层的
		var color: Color = lc["color"]
		var lt: CadLinetype = lc["linetype"]
		var bucket: PackedVector2Array = lc["bucket"]
		if e.aci >= 1 and e.aci <= 255:
			color = e.color
			bucket = _bucket(color, _resolve_width(doc, e))
		if color.a > 0.001:
			if e.linetype != "BYLAYER" and e.linetype != "":
				lt = doc.get_linetype(doc.resolve_linetype(e))
			if lt == null or lt.is_continuous():
				var before := bucket.size()
				e.emit_screen_segments(xf, bucket, sag)
				_seg_count += (bucket.size() - before) / 2
			else:
				for c in e.get_curves():
					_emit_curve(doc, bucket, c, lt, e.linetype_scale, xf, sag, view.zoom)
		drawn += 1

	# 墙体并集轮廓：必须在普通图元之前入桶，使墙线压在被填充的构件之下。
	# 并集按文档 revision 缓存，文档不变时不重算。
	if wall_count > 0:
		_emit_walls(doc, xf)
	_flush(ci, xf)
	_draw_points(doc, view, ci)
	var texts_drawn := _draw_texts(doc, view, ci)
	if not selection.is_empty():
		_draw_selection(doc, view, ci, selection)
	_cached_drawn = drawn
	stats = {
		"cache": "build",
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


## 构建辅助图元清单（按文档版本缓存）。
## 清单本身与视图无关，只有尺寸/颜色的解析才依赖视图。
func _build_aux_lists(doc: CadDocument) -> void:
	if _aux_revision == doc.revision:
		return
	_aux_revision = doc.revision
	_aux_text.clear()
	_aux_points.clear()
	_aux_solids.clear()
	for e in doc.entities:
		if not e.visible:
			continue
		# 图层可见性也要过滤（图元自身的 visible 只管自己）
		if not doc.is_layer_visible(e.layer):
			continue
		if not e.get_annotation_texts().is_empty():
			_aux_text.append(e)
		if e.type == CadEntity.Type.POINT:
			_aux_points.append(e)
		elif e.type == CadEntity.Type.HATCH and (e as EntHatch).is_solid():
			_aux_solids.append(e)


## 几何缓存的键。缩放按档位量化，避免连续缩放时每帧都重建。
## 档位取 2 的对数的 1/3 步长（约每 1.26 倍缩放换一档），
## 兼顾圆弧细分精度与重建频率。
func _geometry_key(doc: CadDocument, view: ViewTransform) -> String:
	var z := maxf(view.zoom, 1.0e-9)
	var bucket := int(round(log(z) / log(2.0) * 3.0))
	return "%d|%d|%s|%.4f|%s|%.4f" % [
		doc.revision, bucket, str(show_lineweight),
		ltscale, str(clip_enabled), sagitta_px]


## 取图层的解析结果，首次访问时构建并缓存
func _layer_info(doc: CadDocument, layer: String) -> Dictionary:
	if _layer_cache.has(layer):
		return _layer_cache[layer]
	var l := doc.get_layer(layer)
	var visible := l == null or l.is_displayable()
	var color := l.color if l != null else Color.WHITE
	var lt_name := l.linetype if l != null else "CONTINUOUS"
	var lw := l.lineweight if l != null else CadLayer.LW_DEFAULT
	var lt := doc.get_linetype(lt_name)
	var width := min_width_px
	if show_lineweight:
		width = clampf((lw if lw >= 0.0 else 0.25) * px_per_mm, min_width_px, max_width_px)
	var info := {
		"visible": visible,
		"color": color,
		"linetype": lt,
		"bucket": _bucket(color, width),
	}
	_layer_cache[layer] = info
	return info


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


## 提交分桶。点是模型坐标，这里用一次 Transform2D 乘法（C++ 循环）
## 把它们整体变换到屏幕空间 —— 这是本渲染器每帧唯一与图元数量相关的开销。
func _flush(ci: CanvasItem, xf: Transform2D) -> void:
	for key in _bucket_pts.keys():
		var pts: PackedVector2Array = _bucket_pts[key]
		if pts.size() < 2:
			continue
		var meta: Array = _bucket_meta[key]
		var color: Color = meta[0]
		var width := maxf(float(meta[1]), min_width_px)
		if clip_enabled:
			# 图纸空间：需要按视口边界裁剪，走逐段裁剪的慢路径
			_flush_clipped(ci, xf, pts, color, width)
		else:
			ci.draw_multiline(xf * pts, color, width)


## 带裁剪的提交路径（图纸空间用）。逐段裁剪无法批量，
## 但图纸空间只在切换布局与改动时重绘，不在交互热路径上。
func _flush_clipped(ci: CanvasItem, xf: Transform2D, pts: PackedVector2Array,
		color: Color, width: float) -> void:
	var out := PackedVector2Array()
	for i in range(0, pts.size() - 1, 2):
		var a := xf * pts[i]
		var b := xf * pts[i + 1]
		var seg := _clip_seg_rect(a, b, clip_rect)
		if seg.size() == 2:
			out.append(seg[0])
			out.append(seg[1])
	if out.size() >= 2:
		ci.draw_multiline(out, color, width)


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
		lt: CadLinetype, lt_scale: float, _xf: Transform2D, sag: float, zoom: float) -> void:
	# 注意：本函数只往桶里写**模型坐标**，不再做屏幕变换。
	# 变换在 _flush 里一次性完成，这是性能的关键 ——
	# 逐图元做 GDScript 变换是原先每帧上百毫秒的根源。
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
		# 入桶的是**模型坐标**；变换统一在 _flush 里做一次
		_append_segments(bucket, poly, c.is_closed())
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
		bucket.append_array(model_pairs)


## 线段入桶（模型坐标）。裁剪不在这里做 ——
## 裁剪属于屏幕空间的事，统一放到 _flush_clipped 里处理。
func _push_seg(bucket: PackedVector2Array, a: Vector2, b: Vector2) -> void:
	bucket.append(a)
	bucket.append(b)


## 线段对矩形裁剪（Liang-Barsky）
static func _clip_seg_rect(a: Vector2, b: Vector2, r: Rect2) -> PackedVector2Array:
	var dx := b.x - a.x
	var dy := b.y - a.y
	var t0 := 0.0
	var t1 := 1.0
	var p := PackedFloat64Array([-dx, dx, -dy, dy])
	var q := PackedFloat64Array([a.x - r.position.x,
		r.position.x + r.size.x - a.x,
		a.y - r.position.y,
		r.position.y + r.size.y - a.y])
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


func _append_segments(bucket: PackedVector2Array, pts: PackedVector2Array, closed: bool) -> void:
	if _seg_count >= max_segments:
		_overflow = true
		return
	var n := pts.size()
	for i in range(n - 1):
		_push_seg(bucket, pts[i], pts[i + 1])
	# 闭合折线补上首尾段（细分结果通常已首尾重合，故先判重）
	if closed and n > 2 and not pts[0].is_equal_approx(pts[n - 1]):
		_push_seg(bucket, pts[n - 1], pts[0])
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

## 把墙体并集轮廓输出为线段。
## 每个多边形既画外轮廓也画洞（内环）的轮廓，才能正确表现带天井的平面。
func _emit_walls(doc: CadDocument, view_xf: Transform2D) -> void:
	var outlines := WallUnion.outline(doc)
	if outlines.is_empty():
		return
	var lw := 1.0
	if show_lineweight:
		var l := doc.get_layer("墙体")
		lw = clampf((l.lineweight if l != null else 1.0) * px_per_mm, min_width_px, max_width_px)
	var color := Color(0.95, 0.95, 0.92)
	var l := doc.get_layer("墙体")
	if l != null:
		color = l.color
	var bucket := _bucket(color, lw)
	for poly in outlines:
		var pts: PackedVector2Array = poly
		if pts.size() < 3:
			continue
		var _unused := view_xf
		for i in range(pts.size()):
			_push_seg(bucket, pts[i], pts[(i + 1) % pts.size()])
		_seg_count += pts.size()


## 展开块引用：把块内图元按插入变换落到模型空间，逐个解析颜色后入桶。
func _emit_insert(doc: CadDocument, view: ViewTransform, ins: EntInsert,
		view_xf: Transform2D, sag: float) -> void:
	var blk := ins.get_block()
	if blk == null:
		return
	var ins_xf := ins.insert_transform()
	for be in blk.entities:
		if not be.visible:
			continue
		var color := _resolve_block_color(doc, be, ins)
		if color.a <= 0.001:
			continue
		var width := _resolve_width(doc, be)
		var bucket := _bucket(color, width)
		var lt := doc.get_linetype(doc.resolve_linetype(be))
		for c in be.get_curves():
			var t := c.transformed(ins_xf)
			if t == null:
				continue
			_emit_curve(doc, bucket, t, lt, be.linetype_scale, view_xf, sag, view.zoom)


## 解析块内图元的颜色。aci == 0 表示随块（BYBLOCK），取引用自身的颜色。
func _resolve_block_color(doc: CadDocument, be: CadEntity, ins: EntInsert) -> Color:
	if be.aci == 0:
		if ins.aci == 0 or ins.aci == 256:
			var l := doc.get_layer(ins.layer)
			return l.color if l != null else Color.WHITE
		return ins.color
	return doc.resolve_color(be)


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
	# 存模型坐标，提交时统一变换 —— 与线几何走同一套缓存策略
	var _unused := view
	_solid_items.append({"poly": ring, "model": true, "color": doc.resolve_color(h)})


func _draw_solids(_view: ViewTransform, ci: CanvasItem) -> int:
	var n := 0
	for item in _solid_items:
		var poly: PackedVector2Array = item["poly"]
		if poly.size() < 3:
			continue
		var col: Color = item["color"]
		var xf2 := _view.transform() if item.has("model") else Transform2D()
		if item.has("model"):
			poly = xf2 * poly
		ci.draw_colored_polygon(poly, Color(col.r, col.g, col.b, maxf(col.a, 1.0)))
		n += 1
	return n


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
