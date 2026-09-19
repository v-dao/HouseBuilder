class_name P6Tests
extends TestSuite
## 文件 I/O 与出图的测试：自有格式 .hbd、SVG 导出。


func run() -> void:
	suite = "自有格式：往返"
	_test_roundtrip_all_types()
	_test_compression()
	_test_reject_garbage()
	_test_blocks_after_load()

	suite = "SVG 导出"
	_test_svg_structure()
	_test_svg_escaping()

	suite = "DXF 导出（R12）"
	_test_dxf_structure()
	_test_dxf_entities()
	_test_dxf_chinese()
	_test_dxf_layer_table()


func _tmp(name: String) -> String:
	return "user://" + name


## 造一份包含全部图元类型与数据表的文档
func _make_doc() -> CadDocument:
	var doc := CadDocument.new()
	GbBlocks.install(doc)
	doc.plot_scale = 100.0
	doc.ltscale = 20.0
	# 自定义图层
	doc.layers["测试层"] = CadLayer.make("测试层", Color(0.2, 0.9, 0.4), 3,
		"DASHED", 0.5, "往返测试用")
	# 各类图元
	_add(doc, EntLine.make(Vector2(0, 0), Vector2(1000, 500)), "0")
	_add(doc, EntCircle.make(Vector2(500, 500), 250.0), "0")
	_add(doc, EntArc.make(Vector2(0, 0), 400.0, 0.3, 2.1), "0")
	_add(doc, EntPolyline.make(
		PackedVector2Array([Vector2(0, 0), Vector2(800, 0), Vector2(800, 600)]),
		PackedFloat64Array([0.5, 0.0, 0.0]), false), "测试层")
	_add(doc, EntEllipse.make(Vector2(2000, 0), 500.0, 300.0, 0.4, 0.0, 5.0), "0")
	_add(doc, EntSpline.make(PackedVector2Array([
		Vector2(0, 2000), Vector2(500, 2600), Vector2(1200, 2200)]), false), "0")
	_add(doc, EntPoint.make(Vector2(3000, 3000)), "0")
	_add(doc, EntText.make(Vector2(100, 100), "往返测试 ±0.000", 5.0, 0.3), "测试层")
	_add(doc, EntMText.make(Vector2(0, 4000), "第一行\n第二行", 7.0), "0")
	_add(doc, EntXline.make(Vector2(0, 0), Vector2(0.7071, 0.7071), true), "0")
	_add(doc, EntHatch.make(PackedVector2Array([
		Vector2(100, 100), Vector2(900, 100), Vector2(900, 700), Vector2(100, 700)]),
		"钢筋混凝土"), "0")
	_add(doc, EntWall.make(PackedVector2Array([Vector2(0, 0), Vector2(6000, 0)]), 240.0), "0")
	_add(doc, EntDim.make_linear(Vector2(0, 0), Vector2(3600, 0), Vector2(1800, -500)), "0")
	_add(doc, EntSymbols.Elevation.make(Vector2(0, 0), 3600.0), "0")
	_add(doc, EntSymbols.AxisBubble.make(Vector2(0, 9000), "3"), "0")
	_add(doc, EntInsert.make("M0921", Vector2(1000, 2000)), "0")
	# 墙体洞口
	var w := EntWall.make(PackedVector2Array([Vector2(0, 0), Vector2(8000, 0)]), 240.0)
	w.add_opening(2000.0, 900.0, "M0921", false)
	w.add_opening(6000.0, 1500.0, "C1515", true)
	_add(doc, w, "0")
	return doc


func _add(doc: CadDocument, e: CadEntity, layer: String) -> void:
	e.layer = layer
	e.aci = 256
	doc.add_entity(e, false)


func _test_roundtrip_all_types() -> void:
	var doc := _make_doc()
	var path := _tmp("roundtrip.hbd")
	var err := NativeFormat.save(doc, path)
	ok(err == OK, "保存应成功，错误码 %d" % err)

	var doc2 := CadDocument.new()
	var err2 := NativeFormat.load_into(doc2, path)
	ok(err2 == OK, "载入应成功，错误码 %d" % err2)

	ok(doc2.entity_count() == doc.entity_count(),
		"图元数量往返：%d vs %d" % [doc2.entity_count(), doc.entity_count()])
	# 逐类型计数
	var t1 := _type_histogram(doc)
	var t2 := _type_histogram(doc2)
	for k in t1.keys():
		ok(t2.get(k, 0) == t1[k], "类型 %d 数量往返：%d vs %d" % [k, t2.get(k, 0), t1[k]])
	# 数据表
	ok(doc2.layers.has("测试层"), "自定义图层应往返")
	var l: CadLayer = doc2.layers.get("测试层")
	if l != null:
		ok(l.linetype == "DASHED", "图层线型往返")
		close(l.lineweight, 0.5, "图层线宽往返")
		# 颜色以 8 位十六进制序列化，往返误差不超过 1/255
		ok(absf(l.color.r - 0.2) <= 1.0 / 255.0 and absf(l.color.g - 0.9) <= 1.0 / 255.0
			and absf(l.color.b - 0.4) <= 1.0 / 255.0,
			"图层颜色往返（8bit 量化内），实际 %s" % str(l.color))
	close(doc2.plot_scale, 100.0, "出图比例往返")
	close(doc2.ltscale, 20.0, "线型比例往返")
	ok(doc2.text_styles.size() == doc.text_styles.size(), "文字样式表往返")
	ok(doc2.dim_styles.size() == doc.dim_styles.size(), "标注样式表往返")
	ok(doc2.blocks.size() == doc.blocks.size(), "块表往返")

	# 关键几何：墙体洞口必须精确保留
	var walls1: Array = []
	var walls2: Array = []
	for e in doc.entities:
		if e is EntWall:
			walls1.append(e)
	for e in doc2.entities:
		if e is EntWall:
			walls2.append(e)
	ok(walls1.size() == walls2.size(), "墙体数量往返")
	if walls1.size() == walls2.size() and walls1.size() > 0:
		var wa: EntWall = walls1[walls1.size() - 1]
		var wb: EntWall = walls2[walls2.size() - 1]
		ok(wa.openings.size() == wb.openings.size(), "洞口数量往返")
		close(wb.thickness, wa.thickness, "墙厚往返")
		if wa.openings.size() == wb.openings.size() and wa.openings.size() > 0:
			close((wb.openings[0] as EntWall.Opening).dist,
				(wa.openings[0] as EntWall.Opening).dist, "洞口位置往返", 1e-3)
			ok((wb.openings[1] as EntWall.Opening).is_window,
				"窗洞标记往返")


func _type_histogram(doc: CadDocument) -> Dictionary:
	var h := {}
	for e in doc.entities:
		h[e.type] = int(h.get(e.type, 0)) + 1
	return h


func _test_compression() -> void:
	var doc := _make_doc()
	var p1 := _tmp("plain.hbd")
	var p2 := _tmp("packed.hbd")
	NativeFormat.save(doc, p1, false)
	NativeFormat.save(doc, p2, true)
	var f := FileAccess.open(p2, FileAccess.READ)
	ok(f != null, "压缩文件应可读")
	if f != null:
		var head := f.get_buffer(4).get_string_from_utf8()
		f.close()
		ok(head == "HBZ1", "压缩文件应以 HBZ1 魔数开头，实际 %s" % head)
	# 压缩后应更小
	var s1 := FileAccess.open(p1, FileAccess.READ).get_length()
	var s2 := FileAccess.open(p2, FileAccess.READ).get_length()
	ok(s2 < s1, "压缩后体积应更小：%d -> %d" % [s1, s2])
	# 压缩文件同样能读回
	var doc2 := CadDocument.new()
	ok(NativeFormat.load_into(doc2, p2) == OK, "压缩文件应能载入")
	ok(doc2.entity_count() == doc.entity_count(), "压缩文件的图元数量一致")


func _test_reject_garbage() -> void:
	# 不存在的文件
	var doc := CadDocument.new()
	ok(NativeFormat.load_into(doc, _tmp("不存在.hbd")) != OK, "不存在的文件应报错")
	# 非法内容
	var p := _tmp("garbage.hbd")
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string("这不是一个 HBD 文件")
	f.close()
	ok(NativeFormat.load_into(doc, p) != OK, "非法内容应报错")
	# 合法 JSON 但缺少标记
	var p2 := _tmp("nomark.hbd")
	var f2 := FileAccess.open(p2, FileAccess.WRITE)
	f2.store_string('{"version":1}')
	f2.close()
	ok(NativeFormat.load_into(doc, p2) != OK, "缺少标记的文件应报错")


## 块引用必须在载入后能解析到块定义（块要先于图元载入）
func _test_blocks_after_load() -> void:
	var doc := _make_doc()
	var path := _tmp("blocks.hbd")
	NativeFormat.save(doc, path)
	var doc2 := CadDocument.new()
	NativeFormat.load_into(doc2, path)
	var ins_count := 0
	for e in doc2.entities:
		if not (e is EntInsert):
			continue
		ins_count += 1
		var ins := e as EntInsert
		var blk := doc2.get_block(ins.block_name)
		ok(blk != null, "块引用 %s 应能解析到块定义" % ins.block_name)
		if blk != null:
			ok(not ins.get_curves().is_empty(), "块引用应能展开出几何")
	ok(ins_count > 0, "测试文档应含块引用")


# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------

func _test_svg_structure() -> void:
	var doc := _make_doc()
	var w := SvgWriter.new(doc.plot_scale)
	var svg := w.write(doc)
	ok(svg.begins_with("<?xml"), "SVG 应以 XML 声明开头")
	ok(svg.contains("<svg"), "应含 svg 根元素")
	ok(svg.contains("</svg>"), "svg 根元素应闭合")
	ok(svg.contains('xmlns="http://www.w3.org/2000/svg"'), "应含命名空间")
	ok(svg.contains('width="'), "应含宽度")
	ok(svg.contains("</g>"), "应有分组闭合")
	# 必须含各类型的几何元素
	ok(svg.contains("<line"), "应输出线段")
	ok(svg.contains("<polyline"), "应输出折线（圆、弧、多段线都走这条）")
	ok(svg.contains("<text"), "应输出文字")
	ok(svg.contains("往返测试"), "中文文字内容应原样写入")
	# 图层分组：自定义图层名应出现
	ok(svg.contains('id="测试层"'), "应按图层分组并带上图层名")
	# 虚线图层应输出 dasharray
	ok(svg.contains("stroke-dasharray"), "虚线图层应输出 stroke-dasharray")
	# Y 轴翻转
	ok(svg.contains("scale(1,-1)"), "应包含 Y 轴翻转变换")
	# 字体族
	ok(svg.contains("FangSong"), "应指定仿宋字体族")

	# 写入文件并确认能被解析为文本
	var path := _tmp("export.svg")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(svg)
	f.close()
	ok(FileAccess.file_exists(path), "SVG 文件应已写出")
	var back := FileAccess.open(path, FileAccess.READ).get_as_text()
	ok(back.length() == svg.length(), "写出的字节数与内容长度一致")


func _test_svg_escaping() -> void:
	var doc := CadDocument.new()
	# 图层名与文字里带上 XML 特殊字符
	doc.layers["A<B>&C"] = CadLayer.make("A<B>&C", Color.WHITE, 7, "CONTINUOUS", 0.25)
	var t := EntText.make(Vector2(0, 0), "5 < 6 & 7 > 4", 5.0)
	t.layer = "A<B>&C"
	doc.add_entity(t, false)
	var w := SvgWriter.new(100.0)
	var svg := w.write(doc)
	ok(not svg.contains("A<B>&C"), "图层名里的特殊字符应被转义")
	ok(svg.contains("&lt;B&gt;"), "小于号与大于号应转义")
	ok(svg.contains("&amp;"), "和号应转义")
	ok(not svg.contains("5 < 6"), "文字内容里的尖括号应转义")
	ok(svg.contains("5 &lt; 6"), "转义后的文字内容")


# ---------------------------------------------------------------------------
# DXF 导出
#
# 不用"字符串包含"来验证，而是把组码流解析成 (code, value) 序列再逐项检查 ——
# 这样才能真正验证结构合法、实体字段齐全，也为将来的 DXF 导入打好基础。
# ---------------------------------------------------------------------------

func _dxf_doc() -> CadDocument:
	var doc := CadDocument.new()
	GbBlocks.install(doc)
	doc.layers["测试层"] = CadLayer.make("测试层", Color(0.2, 0.9, 0.4), 3, "DASHED", 0.5)
	var l := EntLine.make(Vector2(0, 0), Vector2(1000, 500))
	l.layer = "测试层"
	doc.add_entity(l, false)
	var c := EntCircle.make(Vector2(500, 500), 250.0)
	doc.add_entity(c, false)
	var a := EntArc.make(Vector2(0, 0), 400.0, 0.0, PI * 0.5)
	doc.add_entity(a, false)
	var p := EntPolyline.make(
		PackedVector2Array([Vector2(0, 0), Vector2(800, 0), Vector2(800, 600)]),
		PackedFloat64Array([0.5, 0.0, 0.0]), true)
	doc.add_entity(p, false)
	var t := EntText.make(Vector2(100, 100), "一层平面图", 5.0)
	doc.add_entity(t, false)
	var pt := EntPoint.make(Vector2(3000, 3000))
	doc.add_entity(pt, false)
	# 需要打散的类型
	doc.add_entity(EntEllipse.make(Vector2(2000, 0), 500.0, 300.0), false)
	doc.add_entity(EntSpline.make(PackedVector2Array([
		Vector2(0, 2000), Vector2(500, 2600), Vector2(1200, 2200)]), false), false)
	doc.add_entity(EntHatch.make(PackedVector2Array([
		Vector2(100, 100), Vector2(900, 100), Vector2(900, 700), Vector2(100, 700)]),
		"钢筋混凝土"), false)
	doc.add_entity(EntDim.make_linear(Vector2(0, 0), Vector2(3600, 0), Vector2(1800, -500)), false)
	doc.add_entity(EntWall.make(PackedVector2Array([Vector2(0, 0), Vector2(6000, 0)]), 240.0), false)
	doc.add_entity(EntSymbols.Elevation.make(Vector2(0, 0), 3600.0), false)
	doc.add_entity(EntInsert.make("M0921", Vector2(1000, 2000)), false)
	return doc


## 解析组码流为 [[code, value], ...]
func _parse_dxf(data: PackedByteArray) -> Array:
	var text := data.get_string_from_utf8()
	var lines := text.split("\n")
	var out: Array = []
	var i := 0
	while i + 1 < lines.size():
		var code_s := String(lines[i]).strip_edges()
		if code_s == "":
			i += 1
			continue
		out.append([int(code_s), String(lines[i + 1])])
		i += 2
	return out


func _test_dxf_structure() -> void:
	var doc := _dxf_doc()
	var w := DxfWriter.new(doc)
	var data := w.write()
	ok(data.size() > 100, "DXF 应有实质内容，实际 %d 字节" % data.size())

	var tags := _parse_dxf(data)
	ok(tags.size() > 50, "组码数应足够，实际 %d" % tags.size())

	# 段结构：SECTION / ENDSEC 必须配对，并以 EOF 结尾
	var sections := []
	var pending := ""
	var endsec := 0
	for t in tags:
		if int(t[0]) == 2 and pending == "SECTION":
			sections.append(String(t[1]))
		if int(t[0]) == 0 and String(t[1]) == "SECTION":
			pending = "SECTION"
		elif int(t[0]) == 0:
			pending = String(t[1])
		if int(t[0]) == 0 and String(t[1]) == "ENDSEC":
			endsec += 1
	ok(sections.has("HEADER"), "应含 HEADER 段")
	ok(sections.has("TABLES"), "应含 TABLES 段")
	ok(sections.has("BLOCKS"), "应含 BLOCKS 段")
	ok(sections.has("ENTITIES"), "应含 ENTITIES 段")
	ok(endsec == sections.size(), "SECTION 与 ENDSEC 数量应一致：%d vs %d" % [sections.size(), endsec])
	var last: Array = tags[tags.size() - 1]
	ok(int(last[0]) == 0 and String(last[1]) == "EOF", "文件应以 EOF 结束")

	# 版本与单位
	var ver := _find_value(tags, "$ACADVER")
	ok(ver == "AC1009", "应声明为 R12(AC1009)，实际 %s" % ver)
	var units := _find_value(tags, "$INSUNITS")
	ok(units == "4", "$INSUNITS 应为 4（毫米），实际 %s" % units)


func _find_value(tags: Array, name: String) -> String:
	for i in range(tags.size() - 1):
		if int(tags[i][0]) == 9 and String(tags[i][1]) == name:
			return String(tags[i + 1][1])
	return ""


func _count_entities(tags: Array, name: String) -> int:
	var n := 0
	for t in tags:
		if int(t[0]) == 0 and String(t[1]) == name:
			n += 1
	return n


func _test_dxf_entities() -> void:
	var doc := _dxf_doc()
	var tags := _parse_dxf(DxfWriter.new(doc).write())

	# 原生实体必须直接对应
	ok(_count_entities(tags, "LINE") >= 1, "应输出 LINE")
	ok(_count_entities(tags, "CIRCLE") >= 1, "应输出 CIRCLE")
	ok(_count_entities(tags, "ARC") >= 1, "应输出 ARC")
	ok(_count_entities(tags, "POINT") >= 1, "应输出 POINT")
	ok(_count_entities(tags, "TEXT") >= 1, "应输出 TEXT")
	ok(_count_entities(tags, "POLYLINE") >= 1, "应输出 POLYLINE")
	ok(_count_entities(tags, "VERTEX") >= 3, "多段线顶点应逐个输出")
	ok(_count_entities(tags, "SEQEND") >= 1, "POLYLINE 应以 SEQEND 收尾")
	ok(_count_entities(tags, "INSERT") >= 1, "应输出 INSERT")
	ok(_count_entities(tags, "BLOCK") >= 1, "INSERT 引用的块应写入 BLOCKS 段")

	# 每个实体都必须带图层（组码 8）
	var ents := ["LINE", "CIRCLE", "ARC", "POINT", "TEXT", "POLYLINE", "INSERT"]
	for i in range(tags.size() - 1):
		if int(tags[i][0]) == 0 and ents.has(String(tags[i][1])):
			# 向后最多找 12 个组码，应能遇到 8
			var found := false
			for k in range(i + 1, mini(i + 13, tags.size())):
				if int(tags[k][0]) == 8:
					found = true
					break
				if int(tags[k][0]) == 0:
					break
			if not found:
				ok(false, "%s 实体缺少图层组码 8" % String(tags[i][1]))
				break

	# 圆弧角度必须是度
	var arc_deg_ok := true
	for t in tags:
		if int(t[0]) == 50 or int(t[0]) == 51:
			var v := String(t[1]).to_float()
			if absf(v) > 360.1:
				arc_deg_ok = false
	ok(arc_deg_ok, "圆弧角度应为度且在合理范围")

	# 椭圆、样条、填充、标注、墙体、符号都必须被打散，不能留下非法类型
	for bad in ["ELLIPSE", "SPLINE", "HATCH", "DIMENSION", "MTEXT", "LWPOLYLINE"]:
		ok(_count_entities(tags, bad) == 0,
			"R12 不应出现 %s（应已打散）" % bad)


func _test_dxf_chinese() -> void:
	var doc := _dxf_doc()
	var data := DxfWriter.new(doc).write()
	# 「一层平面图」的 GBK 编码应为 D2BB B2E3 C6BD C3E6 CDBC
	var expect := PackedByteArray([0xD2, 0xBB, 0xB2, 0xE3, 0xC6, 0xBD, 0xC3, 0xE6, 0xCD, 0xBC])
	var found := false
	for i in range(data.size() - expect.size() + 1):
		var hit := true
		for k in range(expect.size()):
			if data[i + k] != expect[k]:
				hit = false
				break
		if hit:
			found = true
			break
	ok(found, "中文应以 GBK 编码写入（一层平面图 -> D2BBB2E3C6BDC3E6CDBC）")
	ok(Gbk.is_available(), "GBK 映射表应可用")
	# 逐字校验几个常用字
	ok(Gbk.gbk_of("墙".unicode_at(0)) == 0xC7BD, "「墙」的 GBK 码")
	ok(Gbk.gbk_of("A".unicode_at(0)) == -1, "ASCII 不在表中（走直通分支）")
	var enc := Gbk.encode("A墙")
	ok(enc.size() == 3, "ASCII 1 字节 + 汉字 2 字节 = 3")
	ok(enc[0] == 0x41 and enc[1] == 0xC7 and enc[2] == 0xBD, "混合编码结果")


func _test_dxf_layer_table() -> void:
	var doc := _dxf_doc()
	var data := DxfWriter.new(doc).write()
	var tags := _parse_dxf(data)
	# 中文图层名在文件里是 GBK 字节，用 UTF-8 解码后必然不等，
	# 因此按**原始字节**查找，而不是解码后再比对字符串。
	var has_custom := _bytes_contain(data, Gbk.encode("测试层"))
	var layer_entries := 0
	for t in tags:
		if int(t[0]) == 0 and String(t[1]) == "LAYER":
			layer_entries += 1
	ok(has_custom, "图层表应包含自定义图层（按 GBK 字节查找）")
	ok(layer_entries >= doc.layers.size(), "图层条目数应不少于图层数：%d vs %d" % [
		layer_entries, doc.layers.size()])
	# 线型表应含 DASHED
	var has_dashed := false
	for i in range(tags.size() - 1):
		if int(tags[i][0]) == 0 and String(tags[i][1]) == "LTYPE":
			if int(tags[i + 1][0]) == 2 and String(tags[i + 1][1]) == "DASHED":
				has_dashed = true
	ok(has_dashed, "线型表应包含 DASHED")
	# CONTINUOUS 必须在
	var has_cont := false
	for i in range(tags.size() - 1):
		if int(tags[i][0]) == 0 and String(tags[i][1]) == "LTYPE":
			if int(tags[i + 1][0]) == 2 and String(tags[i + 1][1]) == "CONTINUOUS":
				has_cont = true
	ok(has_cont, "线型表必须含 CONTINUOUS")


## 在字节流里查找子串（DXF 用 GBK 编码，不能先解码成字符串再比对）
func _bytes_contain(hay: PackedByteArray, needle: PackedByteArray) -> bool:
	if needle.is_empty() or hay.size() < needle.size():
		return false
	for i in range(hay.size() - needle.size() + 1):
		var hit := true
		for k in range(needle.size()):
			if hay[i + k] != needle[k]:
				hit = false
				break
		if hit:
			return true
	return false
