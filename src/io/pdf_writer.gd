class_name PdfWriter
extends RefCounted
## 矢量 PDF 出图。
##
## 为什么自己写而不是找库：Godot 没有任何 PDF 能力，也没有可用的 GDExtension。
## PDF 1.7 的路径绘制部分其实很简单（m / l / S / f / B 加线宽与虚线），
## 真正难的是中文 —— 必须嵌入字体并做 CID 编码。
##
## 中文方案：Type0 / CIDFontType2 / Identity-H
##   · 文本内容写的是**字形序号(GID)** 而不是 Unicode，故需要解析 TTF 的 cmap
##   · FontFile2 直接嵌入原始 TTF，配合 CIDToGIDMap /Identity，
##     字形数据完全不用重建（代价是嵌入整份字体）
##   · 用 FlateDecode 压缩，simfang 10.5MB 可压到约 5MB
## 这个取舍换来"任何阅读器都能正确显示中文"，对施工图是划算的。

## 纸张尺寸（mm）。默认 A3 横放。
var paper := Vector2(420.0, 297.0)
## 若指定布局，则按布局出图：纸张取布局幅面、内容经布局视口变换，
## 并连同图框与标题栏一起输出 —— 这才是真正的"所见即所得"出图。
var layout: CadLayout = null
## 视口裁剪矩形（PDF 用户单位/磅）。出图时每个视口只应画出自己那一块，
## 否则 1:10 的节点详图里会连带出现整张平面图。
var _clip_pt := Rect2()
var _clip_on := false
## 出图比例（1:100 记 100）。模型毫米 / 该比例 = 图纸毫米。
var plot_scale := 100.0
## 模型空间 -> 图纸空间的自适应缩放（内容超出纸张时自动缩小）
var auto_fit := true

var _objects: Array = []          ## 每个元素是对象的字节内容（不含 obj/endobj 包装）
var _page_scale := 1.0
var _page_offset := Vector2.ZERO
var _ttf: Ttf = null
## 用到的字形：GID -> Unicode 码点。用于生成 ToUnicode CMap，
## 有了它 PDF 里的中文才能被搜索与复制（否则提取出来是字形序号）。
var _used_glyphs := {}
var _font_obj := 0
var _font_desc_obj := 0
var _font_file_obj := 0

## 毫米 -> PDF 点（1 pt = 1/72 英寸）
const MM2PT := 72.0 / 25.4


## 设置字体文件。成功返回是否可用；失败时 PDF 仍能生成，只是文字会缺失。
func set_font(path: String) -> bool:
	_ttf = Ttf.new()
	if not _ttf.load_from_file(path):
		_ttf = null
		return false
	return true


func write(doc: CadDocument) -> PackedByteArray:
	_objects.clear()
	# 1 号与 2 号分别是 Catalog 与 Pages，先占位（它们要引用后面才创建的 Page）
	_objects.append(PackedByteArray())
	_objects.append(PackedByteArray())

	var content := PackedByteArray()
	_compute_page_transform(doc)
	_emit_content(doc, content)
	var content_obj := _add_object(_stream_object(content))
	var font0 := _build_fonts()
	var page_obj := _add_object(_page_object(content_obj, font0))

	_objects[0] = _bytes("<< /Type /Catalog /Pages 2 0 R >>")
	_objects[1] = _bytes("<< /Type /Pages /Kids [%d 0 R] /Count 1 >>" % page_obj)
	return _assemble()


## 追加一个对象，返回它的对象号（对象号 = 下标 + 1）
func _add_object(body: PackedByteArray) -> int:
	_objects.append(body)
	return _objects.size()


func _stream_object(data: PackedByteArray) -> PackedByteArray:
	var packed := data.compress(FileAccess.COMPRESSION_DEFLATE)
	var out := PackedByteArray()
	out.append_array(_bytes("<< /Length %d /Filter /FlateDecode >>\nstream\n" % packed.size()))
	out.append_array(packed)
	out.append_array(_bytes("\nendstream"))
	return out


func _page_object(content_obj: int, font_obj: int) -> PackedByteArray:
	return _bytes("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.3f %.3f] /Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>" % [
		paper.x * MM2PT, paper.y * MM2PT, font_obj, content_obj])


func _font_name() -> String:
	if _ttf != null and _ttf.postscript_name != "":
		return _ttf.postscript_name
	return "EmbeddedCJK"


# ---------------------------------------------------------------------------
# 页面变换
# ---------------------------------------------------------------------------

func _compute_page_transform(doc: CadDocument) -> void:
	if layout != null:
		# 按布局出图：纸张取布局幅面，内容按视口比例摆放。
		# 此时 view 的语义是"图纸毫米"，与纸张坐标一致，故比例恒为 1。
		paper = layout.paper_size()
		_page_scale = 1.0
		_page_offset = Vector2.ZERO
		return
	var bb := doc.get_bbox()
	if bb.size.x <= 0.0 and bb.size.y <= 0.0:
		bb = Rect2(0, 0, 100, 100)
	# 模型毫米 -> 图纸毫米
	var s := 1.0 / maxf(plot_scale, 1.0e-6)
	if auto_fit:
		# 内容加了边距后若仍超出纸张，再等比缩小
		var margin_mm := 10.0
		var need := bb.size * s
		var avail := paper - Vector2(margin_mm * 2.0, margin_mm * 2.0)
		if need.x > avail.x or need.y > avail.y:
			var k := minf(avail.x / maxf(need.x, 1e-6), avail.y / maxf(need.y, 1e-6))
			s *= k
	_page_scale = s
	# 让内容包围盒居中
	var content_mm := bb.size * s
	_page_offset = (paper - content_mm) * 0.5 - bb.position * s


## 模型坐标 -> PDF 用户单位（点）
func _pt(p: Vector2) -> Vector2:
	var mm := p * _page_scale + _page_offset
	# PDF 原点在左下、Y 向上，与模型空间一致，只需换算单位
	return mm * MM2PT


# ---------------------------------------------------------------------------
# 内容流
# ---------------------------------------------------------------------------

func _emit_content(doc: CadDocument, out: PackedByteArray) -> void:
	if layout != null:
		_emit_layout(doc, out)
		return
	var names := doc.layer_names()
	for name in names:
		var l: CadLayer = doc.layers.get(name)
		if l == null or not l.is_displayable():
			continue
		for e in doc.entities:
			if e.layer != name or not e.visible:
				continue
			_emit_entity(doc, e, l, out)


## 按布局出图：白底 + 图框/标题栏/会签栏 + 视口内的模型内容。
## 模型内容按「模型 -> 图纸」变换后绘制，不做裁剪 ——
## 出图时视口本身是按图形范围算出来的，正常不会溢出。
func _emit_layout(doc: CadDocument, out: PackedByteArray) -> void:
	var paper_size := layout.paper_size()
	# 纸张底色
	out.append_array(_bytes("q 1 1 1 rg 0 0 %.3f %.3f re f Q
" % [
		paper_size.x * MM2PT, paper_size.y * MM2PT]))
	# 图框 + 标题栏 + 会签栏：按 1:1 图纸尺寸生成到临时文档后绘制
	var fd := CadDocument.new()
	fd.plot_scale = 1.0
	GbSheet.build_frame(fd, layout.format, layout.portrait, layout.title_fields)
	var saved_doc := doc
	# 图框在图纸坐标系里，比例恒为 1
	_page_scale = 1.0
	_page_offset = Vector2.ZERO
	for name in fd.layer_names():
		var l: CadLayer = fd.layers[name]
		for e in fd.entities:
			if e.layer == name and e.visible:
				_emit_entity(fd, e, l, out)
	# 各视口内的模型内容
	for v in layout.viewports:
		var vp := v as CadLayout.PaperView
		# 模型 -> 图纸：先减去模型中心，除以比例，再平移到视口中心
		for name2 in saved_doc.layer_names():
			var l2: CadLayer = saved_doc.layers[name2]
			if not l2.is_displayable():
				continue
			for e2 in saved_doc.entities:
				if e2.layer != name2 or not e2.visible:
					continue
				_emit_entity_in_view(saved_doc, e2, l2, vp, out)


## 在视口变换下输出图元。做法是把图元坐标先经「模型->图纸」再走常规的 _pt()。
func _emit_entity_in_view(doc: CadDocument, e: CadEntity, l: CadLayer,
		vp: CadLayout.PaperView, out: PackedByteArray) -> void:
	var saved := _page_offset
	var saved_scale := _page_scale
	# _pt() 内部是 p * _page_scale + _page_offset，而视口变换是
	# (p - model_center)/scale + 视口中心，两者可以合并成仿射形式：
	#   缩放 = 1/scale，偏移 = 视口中心 - model_center/scale
	_page_scale = 1.0 / maxf(vp.scale, 1.0e-9)
	_page_offset = vp.paper_rect.position + vp.paper_rect.size * 0.5 - vp.model_center * _page_scale
	# 视口边界即裁剪边界
	var r0 := vp.paper_rect.position * MM2PT
	var r1 := (vp.paper_rect.position + vp.paper_rect.size) * MM2PT
	_clip_pt = Rect2(r0, Vector2.ZERO).merge(Rect2(r1, Vector2.ZERO))
	_clip_on = true
	_emit_entity(doc, e, l, out)
	_clip_on = false
	_page_scale = saved_scale
	_page_offset = saved


func _emit_entity(doc: CadDocument, e: CadEntity, l: CadLayer, out: PackedByteArray) -> void:
	var color := doc.resolve_color(e)
	var lw_mm := e.lineweight if e.lineweight >= 0.0 else l.lineweight
	if lw_mm < 0.0:
		lw_mm = 0.25
	# 线宽是图纸毫米，直接换算成点
	var lw_pt := maxf(lw_mm * MM2PT, 0.1)
	var dash := _dash_array(doc, e)

	# 实心填充
	if e is EntHatch and (e as EntHatch).is_solid():
		var ring := (e as EntHatch).boundary_closed()
		if ring.size() >= 3 and not _ring_outside_clip(ring):
			out.append_array(_bytes("q %.4f %.4f %.4f rg\n" % [color.r, color.g, color.b]))
			_path(out, ring, true)
			out.append_array(_bytes("f\nQ\n"))
		return

	var first := true
	for c in e.get_curves():
		match c.kind():
			GeoCurve.Kind.SEG:
				var s := c as GeoSeg
				_stroke_line(out, color, lw_pt, dash, s.a, s.b, first)
				first = false
			GeoCurve.Kind.ARC:
				var a := c as GeoArc
				var pts := a.tessellate(_sagitta(a))
				_stroke_poly(out, color, lw_pt, dash, pts, a.is_full_circle(), first)
				first = false
			GeoCurve.Kind.POLY:
				var p := c as GeoPoly
				_stroke_poly(out, color, lw_pt, dash, p.tessellate(_sagitta(p)), p.is_closed(), first)
				first = false
			_:
				var pts2 := c.tessellate(_sagitta(c))
				if pts2.size() >= 2:
					_stroke_poly(out, color, lw_pt, dash, pts2, c.is_closed(), first)
					first = false
	# 文字
	for a in e.get_annotation_texts():
		_emit_text(doc, e, color, a, out)


func _sagitta(c: GeoCurve) -> float:
	var bb := c.bbox()
	return maxf(maxf(bb.size.x, bb.size.y) * 1.0e-4, 0.05)


## 线段对矩形裁剪（Liang-Barsky）。返回空数组表示完全在矩形外。
## 视口出图必须裁剪，否则视口外的模型会画到图纸的其他区域上。
static func _clip_seg(a: Vector2, b: Vector2, r: Rect2) -> PackedVector2Array:
	var dx := b.x - a.x
	var dy := b.y - a.y
	var t0 := 0.0
	var t1 := 1.0
	var p := PackedFloat64Array([-dx, dx, -dy, dy])
	var q := PackedFloat64Array([a.x - r.position.x, r.position.x + r.size.x - a.x,
		a.y - r.position.y, r.position.y + r.size.y - a.y])
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


func _stroke_line(out: PackedByteArray, color: Color, lw: float, dash: String,
		a: Vector2, b: Vector2, _first: bool) -> void:
	var pa := _pt(a)
	var pb := _pt(b)
	if _clip_on:
		var seg := _clip_seg(pa, pb, _clip_pt)
		if seg.size() < 2:
			return
		pa = seg[0]
		pb = seg[1]
	out.append_array(_bytes("q %.4f %.4f %.4f RG %.4f w%s\n" % [color.r, color.g, color.b, lw, dash]))
	out.append_array(_bytes("%.3f %.3f m %.3f %.3f l S\nQ\n" % [pa.x, pa.y, pb.x, pb.y]))


func _stroke_poly(out: PackedByteArray, color: Color, lw: float, dash: String,
		pts: PackedVector2Array, closed: bool, _first: bool) -> void:
	if pts.size() < 2:
		return
	# 开启裁剪时逐段裁剪并单独成路径：折线在矩形边界处会被切成若干段，
	# 单条路径无法表达，故放弃折线合并以换取正确性。
	if _clip_on:
		var n := pts.size()
		var limit := n if closed else n - 1
		for i in range(limit):
			_stroke_line(out, color, lw, dash, pts[i], pts[(i + 1) % n], false)
		return
	out.append_array(_bytes("q %.4f %.4f %.4f RG %.4f w%s\n" % [color.r, color.g, color.b, lw, dash]))
	var p0 := _pt(pts[0])
	out.append_array(_bytes("%.3f %.3f m\n" % [p0.x, p0.y]))
	for i in range(1, pts.size()):
		var p := _pt(pts[i])
		out.append_array(_bytes("%.3f %.3f l\n" % [p.x, p.y]))
	out.append_array(_bytes("h\nS\nQ\n" if closed else "S\nQ\n"))


func _path(out: PackedByteArray, pts: PackedVector2Array, closed: bool) -> void:
	if pts.size() < 2:
		return
	var p0 := _pt(pts[0])
	out.append_array(_bytes("%.3f %.3f m\n" % [p0.x, p0.y]))
	for i in range(1, pts.size()):
		var p := _pt(pts[i])
		out.append_array(_bytes("%.3f %.3f l\n" % [p.x, p.y]))
	if closed:
		out.append_array(_bytes("h\n"))


## 线型 -> PDF 虚线数组。pattern 以图纸毫米给出，换算成点。
func _dash_array(doc: CadDocument, e: CadEntity) -> String:
	var lt := doc.get_linetype(doc.resolve_linetype(e))
	if lt == null or lt.is_continuous():
		return ""
	var parts := PackedStringArray()
	for v in lt.pattern:
		# PDF 不接受 0 长度，点用极小值
		parts.append("%.4f" % maxf(absf(v) * maxf(e.linetype_scale, 1.0e-6) * doc.ltscale * MM2PT, 0.05))
	if parts.size() == 0:
		return ""
	return " [%s] 0 d" % " ".join(parts)


# ---------------------------------------------------------------------------
# 文字
# ---------------------------------------------------------------------------

func _emit_text(doc: CadDocument, e: CadEntity, color: Color, a: Dictionary,
		out: PackedByteArray) -> void:
	var txt := String(a.get("text", ""))
	if txt == "":
		return
	var pos: Vector2 = a.get("position", Vector2.ZERO)
	# 文字也要按视口裁剪。几何裁了、文字没裁的话，
	# 1:10 的节点详图里会印出整张平面图的房间名与表格文字 ——
	# 文字在 PDF 里是独立对象，不会跟着路径裁剪走。
	# 做法是整条跳过（不做字形级裁剪）：视口边界的半个字通常无意义。
	if _clip_on and not _clip_pt.grow(200.0).has_point(_pt(pos)):
		return
	var h := float(a.get("height", 3.5))
	var rot := float(a.get("rotation", 0.0))
	var h_align := int(a.get("h_align", EntText.HAlign.LEFT))
	var v_align := int(a.get("v_align", EntText.VAlign.BASELINE))

	# 字号：模型毫米 -> 图纸毫米 -> 点
	var size_pt := h * _page_scale * MM2PT

	if _ttf == null or not _ttf.ok:
		# 没有可用字体时退化为一个细矩形框，至少让人看出这里有文字
		var p := _pt(pos)
		out.append_array(_bytes("q %.4f %.4f %.4f RG 0.5 w %.3f %.3f %.3f %.3f re S Q\n" % [
			color.r, color.g, color.b, p.x, p.y, size_pt * 0.6 * float(txt.length()), size_pt]))
		return

	# 计算文本宽度（用于对齐）与字形序列
	var gids := PackedInt32Array()
	var width_em := 0
	for i in range(txt.length()):
		var cp := txt.unicode_at(i)
		var g := _ttf.glyph_id(cp)
		gids.append(g)
		width_em += _ttf.advance_1000(g)
		if g > 0 and not _used_glyphs.has(g):
			_used_glyphs[g] = cp
	var w_pt := float(width_em) / 1000.0 * size_pt

	# 起始点：按对齐方式回溯
	var origin := pos
	# 提前算好 y 方向偏移（模型空间，Y 向上）
	match v_align:
		EntText.VAlign.TOP:
			origin.y -= h * 0.85
		EntText.VAlign.MIDDLE:
			origin.y -= h * 0.35
		EntText.VAlign.BOTTOM:
			origin.y -= h * 0.1
	var shift := 0.0
	match h_align:
		EntText.HAlign.CENTER, EntText.HAlign.MIDDLE:
			shift = -w_pt * 0.5
		EntText.HAlign.RIGHT:
			shift = -w_pt
	# 沿文字方向平移。PDF 与模型空间都是 Y 向上，方向向量可以直接通用，
	# 不必像 SVG 那样做翻转补偿。
	var cs := cos(rot)
	var sn := sin(rot)
	var origin_pt := _pt(origin) + Vector2(cs, sn) * shift

	var hex := PackedStringArray()
	for g in gids:
		hex.append("%04X" % (g & 0xFFFF))

	out.append_array(_bytes("q %.4f %.4f %.4f rg\n" % [color.r, color.g, color.b]))
	out.append_array(_bytes("BT /F1 %.4f Tf %.5f %.5f %.5f %.5f %.3f %.3f Tm <%s> Tj ET\nQ\n" % [
		size_pt, cs, sn, -sn, cs, origin_pt.x, origin_pt.y, "".join(hex)]))


# ---------------------------------------------------------------------------
# 字体对象
# ---------------------------------------------------------------------------

## 建立字体对象链，返回 Type0 字体的对象号。
## 链：Type0 -> CIDFontType2 -> FontDescriptor -> FontFile2（嵌入的 TTF）
func _build_fonts() -> int:
	if _ttf == null or not _ttf.ok:
		# 没有可用字体：给一个标准 Type1，保证 /F1 引用不悬空、页面仍能打开
		return _add_object(_bytes("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"))
	# 先建后引用者拿不到编号，故先把 FontFile2 与 Descriptor 建好再建 CIDFont
	var ff := _font_file_object()
	var desc := _add_object(_font_descriptor_object(ff))
	var cid := _add_object(_cid_font_object(desc))
	var tounicode := _add_object(_to_unicode_object())
	return _add_object(_bytes(
		"<< /Type /Font /Subtype /Type0 /BaseFont /%s /Encoding /Identity-H /DescendantFonts [%d 0 R] /ToUnicode %d 0 R >>"
		% [_font_name(), cid, tounicode]))


func _font_file_object() -> int:
	var raw := _ttf.data
	var packed := raw.compress(FileAccess.COMPRESSION_DEFLATE)
	var out := PackedByteArray()
	# Length1 是解压后的原始长度，PDF 规范要求
	out.append_array(_bytes("<< /Length %d /Length1 %d /Filter /FlateDecode >>\nstream\n" % [
		packed.size(), raw.size()]))
	out.append_array(packed)
	out.append_array(_bytes("\nendstream"))
	return _add_object(out)


func _font_descriptor_object(file_obj: int) -> PackedByteArray:
	var bb := _ttf.bbox_1000()
	return _bytes("<< /Type /FontDescriptor /FontName /%s /Flags 4 /FontBBox [%d %d %d %d] /ItalicAngle 0 /Ascent %d /Descent %d /CapHeight %d /StemV 80 /FontFile2 %d 0 R >>" % [
		_font_name(), bb[0], bb[1], bb[2], bb[3],
		_ttf.ascent_1000(), _ttf.descent_1000(), _ttf.ascent_1000(), file_obj])


## 生成 ToUnicode CMap 流。
## PDF 规范要求每个 bfchar 块最多 100 项，超过要分包。
## 有了它，阅读器才能把字形反查回 Unicode —— 搜索、复制、无障碍朗读都依赖它。
func _to_unicode_object() -> PackedByteArray:
	var keys: Array = _used_glyphs.keys()
	keys.sort()
	var cmap := PackedStringArray()
	cmap.append("/CIDInit /ProcSet findresource begin")
	cmap.append("12 dict begin")
	cmap.append("begincmap")
	cmap.append("/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def")
	cmap.append("/CMapName /Adobe-Identity-UCS def")
	cmap.append("/CMapType 2 def")
	cmap.append("1 begincodespacerange")
	cmap.append("<0000> <FFFF>")
	cmap.append("endcodespacerange")
	var i := 0
	while i < keys.size():
		var n := mini(100, keys.size() - i)
		cmap.append("%d beginbfchar" % n)
		for k in range(n):
			var gid := int(keys[i + k])
			var cp := int(_used_glyphs[gid])
			cmap.append("<%04X> <%s>" % [gid & 0xFFFF, _utf16be_hex(cp)])
		cmap.append("endbfchar")
		i += n
	cmap.append("endcmap")
	cmap.append("CMapName currentdict /CMap defineresource pop")
	cmap.append("end")
	cmap.append("end")
	# 不压缩：CMap 本身只有几百字节，压缩没有收益，
	# 留着明文便于出问题时直接看出字形映射对不对。
	var body := "\n".join(cmap).to_utf8_buffer()
	var o := PackedByteArray()
	o.append_array(_bytes("<< /Length %d >>\nstream\n" % body.size()))
	o.append_array(body)
	o.append_array(_bytes("\nendstream"))
	return o


## 把码点编成 UTF-16BE 的十六进制。BMP 之外的字符要写代理对。
static func _utf16be_hex(cp: int) -> String:
	if cp < 0x10000:
		return "%04X" % cp
	var v := cp - 0x10000
	var hi := 0xD800 + (v >> 10)
	var lo := 0xDC00 + (v & 0x3FF)
	return "%04X%04X" % [hi, lo]


func _cid_font_object(desc_obj: int) -> PackedByteArray:
	return _bytes("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /%s /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor %d 0 R /CIDToGIDMap /Identity /DW 1000 >>" % [
		_font_name(), desc_obj])


# ---------------------------------------------------------------------------
# 组装文件
# ---------------------------------------------------------------------------

func _bytes(s: String) -> PackedByteArray:
	return s.to_utf8_buffer()


static func _pad10(n: int) -> String:
	return "%010d" % n


func _assemble() -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array(_bytes("%PDF-1.7\n"))
	# PDF 建议带二进制标记，让传输工具按二进制处理
	out.append_array(PackedByteArray([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
	var offsets := PackedInt64Array()
	offsets.resize(_objects.size())
	for i in range(_objects.size()):
		var body: PackedByteArray = _objects[i]
		if body.is_empty():
			body = _bytes("<< >>")
		offsets[i] = out.size()
		out.append_array(_bytes("%d 0 obj\n" % (i + 1)))
		out.append_array(body)
		out.append_array(_bytes("\nendobj\n"))
	var xref_off := out.size()
	out.append_array(_bytes("xref\n0 %d\n" % (_objects.size() + 1)))
	out.append_array(_bytes("0000000000 65535 f \n"))
	for i in range(_objects.size()):
		out.append_array(_bytes("%s 00000 n \n" % _pad10(offsets[i])))
	out.append_array(_bytes("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % [
		_objects.size() + 1, xref_off]))
	return out


func save(doc: CadDocument, path: String) -> Error:
	var data := write(doc)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(data)
	f.close()
	return OK


## 轮廓是否完全落在裁剪矩形之外（完全在外就整块跳过，避免画到图纸别处）
func _ring_outside_clip(ring: PackedVector2Array) -> bool:
	if not _clip_on:
		return false
	for p in ring:
		if _clip_pt.has_point(_pt(p)):
			return false
	return true
