class_name SvgWriter
extends RefCounted
## SVG 矢量导出。
##
## 定位：**矢量出图的快速通道**。DXF 用于和设计院交换，PDF 用于正式出图，
## SVG 则便于在浏览器里预览、以及交给其他排版工具。
##
## 实现要点：
##   · 按图层分组，每组一个 <g>，描边色取自图层颜色，线宽取自国标线宽
##   · 模型的 Y 轴向上，SVG 的 Y 轴向下，故整体套一个翻转变换
##   · 虚线用 stroke-dasharray 直接映射线型 pattern
##   · 文字用 <text>，字体族写长仿宋可用的候选（浏览器/阅读器按顺序回退）

## 导出的每毫米对应多少 SVG 用户单位。1 表示按模型尺寸直接输出（mm）。
var scale: float = 1.0
## 出图比例。线宽与虚线的 pattern 都以图纸毫米给出，需要乘它换算到模型空间。
var plot_scale: float = 100.0


func _init(p_plot_scale := 100.0) -> void:
	plot_scale = p_plot_scale


## 导出整个文档到 SVG 文本
func write(doc: CadDocument, only_visible_layers := true) -> String:
	var bb := doc.get_bbox()
	if bb.size.x <= 0.0 and bb.size.y <= 0.0:
		bb = Rect2(0, 0, 1000, 1000)
	# 留一点边距
	bb = bb.grow(maxf(bb.size.length() * 0.02, 10.0))

	var out := PackedStringArray()
	out.append('<?xml version="1.0" encoding="UTF-8"?>')
	out.append('<svg xmlns="http://www.w3.org/2000/svg" version="1.1"')
	out.append('     font-family="%s"' % font_family())
	out.append('     width="%.3fmm" height="%.3fmm" viewBox="0 0 %.3f %.3f">' % [
		bb.size.x * scale, bb.size.y * scale, bb.size.x * scale, bb.size.y * scale])
	out.append('<desc>由房屋建筑软件导出</desc>')
	# 模型 Y 向上，SVG Y 向下：翻转 Y 并把原点移到包围盒左下
	out.append('<g transform="translate(0,%.3f) scale(1,-1)">' % (bb.size.y * scale))
	out.append('<rect x="%.3f" y="%.3f" width="%.3f" height="%.3f" fill="#ffffff"/>' % [
		bb.position.x * scale, bb.position.y * scale,
		bb.size.x * scale, bb.size.y * scale])

	# 按图层分组
	var names := doc.layer_names()
	for name in names:
		var l: CadLayer = doc.layers.get(name)
		if l == null:
			continue
		if only_visible_layers and not l.is_displayable():
			continue
		var body := PackedStringArray()
		for e in doc.entities:
			if e.layer != name or not e.visible:
				continue
			_emit_entity(e, doc, l, body)
		# 注意：几何为空时只能跳过**几何分组**，不能让整个图层 continue ——
		# 文字层往往只有文字没有几何，提前 continue 会把它的内容整块丢掉。
		if body.size() > 0:
			out.append('<g id="%s" fill="none" stroke="%s" stroke-width="%.3f" stroke-linecap="round" stroke-linejoin="round">' % [
				_xml_escape(name), _hex(l.color), _stroke_width(l)])
			out.append_array(body)
			out.append('</g>')
		# 该层的文字单独一组（文字要填充不要描边）
		var texts := PackedStringArray()
		for e in doc.entities:
			if e.layer != name or not e.visible:
				continue
			_emit_texts(e, doc, l, texts)
		if texts.size() > 0:
			out.append('<g id="%s_text" fill="%s" stroke="none">' % [
				_xml_escape(name), _hex(l.color)])
			out.append_array(texts)
			out.append('</g>')
	out.append('</g>')
	out.append('</svg>')
	return "\n".join(out)


func _stroke_width(l: CadLayer) -> float:
	var w := l.lineweight
	if w < 0.0:
		w = 0.25
	return maxf(w * plot_scale * scale, 0.05)


func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


func _xml_escape(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


func _n(v: float) -> String:
	return "%.4f" % (v * scale)


# ---------------------------------------------------------------------------
# 图元
# ---------------------------------------------------------------------------

func _emit_entity(e: CadEntity, doc: CadDocument, l: CadLayer, out: PackedStringArray) -> void:
	var dash := _dash_attr(doc, e)
	# 实心填充单独处理
	if e is EntHatch and (e as EntHatch).is_solid():
		var ring := (e as EntHatch).boundary_closed()
		if ring.size() >= 3:
			out.append(_polys_to_path([ring], doc.resolve_color(e), true, ""))
		return
	for c in e.get_curves():
		match c.kind():
			GeoCurve.Kind.SEG:
				var s := c as GeoSeg
				out.append('<line x1="%s" y1="%s" x2="%s" y2="%s"%s/>' % [
					_n(s.a.x), _n(s.a.y), _n(s.b.x), _n(s.b.y), dash])
			GeoCurve.Kind.ARC:
				_emit_arc(c as GeoArc, dash, out)
			GeoCurve.Kind.POLY:
				_emit_poly(c as GeoPoly, dash, out)
			_:
				# 椭圆与样条：按细分折线输出
				var pts := c.tessellate(_sagitta(c))
				if pts.size() >= 2:
					out.append('<polyline points="%s"%s/>' % [_points_str(pts), dash])


func _sagitta(c: GeoCurve) -> float:
	var bb := c.bbox()
	return maxf(maxf(bb.size.x, bb.size.y) * 1.0e-4, 0.01)


func _emit_arc(a: GeoArc, dash: String, out: PackedStringArray) -> void:
	var pts := a.tessellate(_sagitta(a))
	if pts.size() < 2:
		return
	out.append('<polyline points="%s"%s/>' % [_points_str(pts), dash])


func _emit_poly(p: GeoPoly, dash: String, out: PackedStringArray) -> void:
	var pts := p.tessellate(_sagitta(p))
	if pts.size() < 2:
		return
	out.append('<polyline points="%s"%s/>' % [_points_str(pts), dash])


func _points_str(pts: PackedVector2Array) -> String:
	var parts := PackedStringArray()
	for p in pts:
		parts.append("%s,%s" % [_n(p.x), _n(p.y)])
	return " ".join(parts)


func _polys_to_path(rings: Array, color: Color, filled: bool, dash: String) -> String:
	var d := PackedStringArray()
	for r in rings:
		var pts: PackedVector2Array = r
		if pts.size() < 3:
			continue
		d.append("M %s %s" % [_n(pts[0].x), _n(pts[0].y)])
		for i in range(1, pts.size()):
			d.append("L %s %s" % [_n(pts[i].x), _n(pts[i].y)])
		d.append("Z")
	var style := ""
	if filled:
		style = ' fill="%s" stroke="none"' % _hex(color)
	elif dash != "":
		style = dash
	return '<path d="%s"%s/>' % [" ".join(d), style]


## 线型 -> stroke-dasharray。pattern 以图纸毫米给出，乘出图比例换算到模型空间。
func _dash_attr(doc: CadDocument, e: CadEntity) -> String:
	var lt := doc.get_linetype(doc.resolve_linetype(e))
	if lt == null or lt.is_continuous():
		return ""
	var parts := PackedStringArray()
	for v in lt.pattern:
		var mm := absf(v) * plot_scale * maxf(e.linetype_scale, 1.0e-6) * doc.ltscale
		# SVG 不接受 0 长度，点用极小值近似
		parts.append("%.4f" % maxf(mm * scale, 0.01))
	if parts.size() == 0:
		return ""
	return ' stroke-dasharray="%s"' % " ".join(parts)


# ---------------------------------------------------------------------------
# 文字
# ---------------------------------------------------------------------------

func _emit_texts(e: CadEntity, doc: CadDocument, l: CadLayer, out: PackedStringArray) -> void:
	for a in e.get_annotation_texts():
		var txt := String(a.get("text", ""))
		if txt == "":
			continue
		var pos: Vector2 = a.get("position", Vector2.ZERO)
		var h := float(a.get("height", 3.5))
		var rot := float(a.get("rotation", 0.0))
		var h_align := int(a.get("h_align", EntText.HAlign.LEFT))
		var v_align := int(a.get("v_align", EntText.VAlign.BASELINE))
		var anchor := "start"
		match h_align:
			EntText.HAlign.CENTER, EntText.HAlign.MIDDLE:
				anchor = "middle"
			EntText.HAlign.RIGHT:
				anchor = "end"
		var baseline := "auto"
		match v_align:
			EntText.VAlign.TOP:
				baseline = "hanging"
			EntText.VAlign.MIDDLE:
				baseline = "middle"
			EntText.VAlign.BOTTOM:
				baseline = "auto"
		# SVG 的 Y 已翻转，旋转角要取负；且文字本身要再翻一次才不倒置
		var tf := ""
		if absf(rot) > 1.0e-9:
			tf = ' transform="translate(%s,%s) rotate(%s) scale(1,-1)"' % [
				_n(pos.x), _n(pos.y), "%.6f" % rad_to_deg(-rot)]
		else:
			tf = ' transform="translate(%s,%s) scale(1,-1)"' % [_n(pos.x), _n(pos.y)]
		out.append('<text x="0" y="0" font-size="%s" text-anchor="%s" dominant-baseline="%s"%s>%s</text>' % [
			_n(h), anchor, baseline, tf, _xml_escape(txt)])


## SVG 里中文字体族：按可用性从优到劣排列。
## 长仿宋不是通用字体名，故先列仿宋，再列常见的宋体类回退。
static func font_family() -> String:
	return "FangSong, 仿宋, STFangsong, SimSun, 宋体, Source Han Serif SC, serif"
