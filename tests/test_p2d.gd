class_name P2dTests
extends TestSuite
## 多行文字（MTEXT）的测试。
##
## 重点：自动换行按"字宽单位"折行（汉字 1.0、拉丁 0.5），
## 以及九种对齐方式的偏移推导 —— 后者极易把符号写反。


func run() -> void:
	suite = "多行文字：字宽单位"
	_test_char_units()

	suite = "多行文字：折行"
	_test_layout_no_wrap()
	_test_layout_wrap()
	_test_layout_paragraphs()

	suite = "多行文字：对齐"
	_test_attach_offsets()
	_test_annotation_positions()

	suite = "多行文字：其他"
	_test_rotation()
	_test_explode_and_roundtrip()


func _test_char_units() -> void:
	close(EntMText.char_units("一".unicode_at(0)), 1.0, "汉字占 1 个字宽")
	close(EntMText.char_units("A".unicode_at(0)), 0.5, "拉丁字母占 0.5 个字宽")
	close(EntMText.char_units("7".unicode_at(0)), 0.5, "阿拉伯数字占 0.5 个字宽")
	close(EntMText.char_units("，".unicode_at(0)), 1.0, "中文标点占 1 个字宽")
	close(EntMText.string_units("墙体"), 2.0, "两个汉字 = 2 个字宽")
	close(EntMText.string_units("C30"), 1.5, "C30 = 1.5 个字宽")


func _test_layout_no_wrap() -> void:
	var e := EntMText.make(Vector2.ZERO, "第一行", 10.0)
	var lines := e.layout_lines()
	ok(lines.size() == 1, "无换行符时应为一行")
	ok(lines[0] == "第一行", "行内容")

	# width <= 0 时不自动折行，即使内容很长
	var e2 := EntMText.make(Vector2.ZERO, "一".repeat(40), 10.0)
	ok(e2.layout_lines().size() == 1, "未给字宽时不应折行")


func _test_layout_wrap() -> void:
	# 字高 10、宽高比 0.7 -> 单字宽 7mm；给定字宽 70mm -> 每行 10 个字宽
	var e := EntMText.make(Vector2.ZERO, "一".repeat(25), 10.0)
	e.width = 70.0
	close(e.height * e.effective_width_factor(), 7.0, "单字宽 = 字高 × 0.7", 1e-6)
	var lines := e.layout_lines()
	ok(lines.size() == 3, "25 个汉字按每行 10 个折行应得 3 行，实际 %d" % lines.size())
	if lines.size() == 3:
		close(float(lines[0].length()), 10.0, "第一行 10 字")
		close(float(lines[1].length()), 10.0, "第二行 10 字")
		close(float(lines[2].length()), 5.0, "第三行 5 字")
	# 折行后内容必须完整保留，不丢字
	var total := ""
	for l in lines:
		total += l
	ok(total == "一".repeat(25), "折行后总字数应与原文一致，实际 %d" % total.length())

	# 拉丁字母按 0.5 字宽计，同样字宽下每行能放 20 个
	var e2 := EntMText.make(Vector2.ZERO, "A".repeat(45), 10.0)
	e2.width = 70.0
	ok(e2.layout_lines().size() == 3, "45 个拉丁字母按每行 20 个应得 3 行，实际 %d" % e2.layout_lines().size())


func _test_layout_paragraphs() -> void:
	var e := EntMText.make(Vector2.ZERO, "第一段\n第二段\n第三段", 10.0)
	var lines := e.layout_lines()
	ok(lines.size() == 3, "三个段落应得三行，实际 %d" % lines.size())
	ok(lines[1] == "第二段", "段落内容按序")
	# 空段落应保留为一个空行
	var e2 := EntMText.make(Vector2.ZERO, "A\n\nB", 10.0)
	ok(e2.layout_lines().size() == 3, "空段落应占一行")


func _test_attach_offsets() -> void:
	var e := EntMText.make(Vector2.ZERO, "测试", 10.0)
	# 构造一个确定的块尺寸：字宽 7mm × 2 字 = 14mm，单行高 10mm
	var size := Vector2(14.0, 10.0)
	close(e.block_size().x, 14.0, "单行 2 汉字的块宽 = 14mm", 1e-6)
	close(e.block_size().y, 10.0, "单行块高 = 字高", 1e-6)

	# 左对齐：块左边缘在原点，因每行居中绘制，行中心在 +宽/2
	e.attach = EntMText.Attach.TOP_LEFT
	vclose(e._attach_offset(size), Vector2(7.0, 5.0), "左上对齐的偏移", 1e-6)
	e.attach = EntMText.Attach.TOP_CENTER
	vclose(e._attach_offset(size), Vector2(0.0, 5.0), "中上对齐的偏移", 1e-6)
	e.attach = EntMText.Attach.TOP_RIGHT
	vclose(e._attach_offset(size), Vector2(-7.0, 5.0), "右上对齐的偏移", 1e-6)
	# 垂直居中：块中心在原点
	e.attach = EntMText.Attach.MIDDLE_CENTER
	vclose(e._attach_offset(size), Vector2(0.0, 0.0), "正中 对齐的偏移", 1e-6)
	e.attach = EntMText.Attach.MIDDLE_LEFT
	vclose(e._attach_offset(size), Vector2(7.0, 0.0), "左中对齐的偏移", 1e-6)
	# 底部：块下边缘在原点
	e.attach = EntMText.Attach.BOTTOM_LEFT
	vclose(e._attach_offset(size), Vector2(7.0, -5.0), "左下对齐的偏移", 1e-6)
	e.attach = EntMText.Attach.BOTTOM_RIGHT
	vclose(e._attach_offset(size), Vector2(-7.0, -5.0), "右下对齐的偏移", 1e-6)


func _test_annotation_positions() -> void:
	# 三行文字，行距 1.5，字高 10 -> 行间距 15mm
	var e := EntMText.make(Vector2(1000, 2000), "一\n二\n三", 10.0)
	e.attach = EntMText.Attach.TOP_LEFT
	e.line_spacing = 1.5
	var anns := e.get_annotation_texts()
	ok(anns.size() == 3, "三行文字应产生三条注记，实际 %d" % anns.size())
	if anns.size() != 3:
		return
	# 每行只有一个汉字，故块宽 = 1 字宽 = 字高 10 × 0.7 = 7mm，半宽 3.5mm。
	# 第一行中心 = position + (半宽, 字高/2) = (1000+3.5, 2000+5)
	vclose(anns[0]["position"], Vector2(1003.5, 2005.0), "第一行中心位置", 1e-4)
	vclose(anns[1]["position"], Vector2(1003.5, 2020.0), "第二行中心位置（下移一个行距）", 1e-4)
	vclose(anns[2]["position"], Vector2(1003.5, 2035.0), "第三行中心位置", 1e-4)
	for a in anns:
		close(float(a["height"]), 10.0, "注记字高")
		ok(int(a["h_align"]) == EntText.HAlign.CENTER, "每行按居中绘制")
		ok(int(a["v_align"]) == EntText.VAlign.MIDDLE, "每行垂直居中于行高")

	# 空行不产生注记
	var e2 := EntMText.make(Vector2.ZERO, "A\n\nB", 10.0)
	ok(e2.get_annotation_texts().size() == 2, "空行不产生文字注记")


func _test_rotation() -> void:
	# 旋转 90° 后：局部 +Y（向下）映射到世界 -X
	var e := EntMText.make(Vector2.ZERO, "一", 10.0)
	e.attach = EntMText.Attach.TOP_LEFT
	e.rotation = PI * 0.5
	var anns := e.get_annotation_texts()
	ok(anns.size() == 1, "单行文字一条注记")
	if anns.size() == 1:
		# 局部偏移 (半宽 3.5, 半高 5)，旋转 90° 后 (-3.5, 5) -> (x', y') = (-y, x) = (-5, 3.5)
		vclose(anns[0]["position"], Vector2(-5.0, 3.5), "旋转 90° 后的文字位置", 1e-4)
		close(float(anns[0]["rotation"]), PI * 0.5, "注记旋转角")
	# 包围盒应随之旋转
	var bb := e.get_bbox()
	ok(bb.size.x > 0.0 and bb.size.y > 0.0, "旋转后的包围盒应有面积")


func _test_explode_and_roundtrip() -> void:
	var doc := CadDocument.new()
	var e := EntMText.make(Vector2(500, 600), "第一行\n第二行", 7.0)
	e.width = 200.0
	e.attach = EntMText.Attach.MIDDLE_CENTER
	e.rotation = 0.3
	e.line_spacing = 1.8
	e.text_style = "仿宋_3.5"
	e.layer = "文字"
	e.aci = 256
	doc.add_entity(e, false)

	# 拆解为单行文字
	var parts := e.explode()
	ok(parts.size() == 2, "两行文字应拆出 2 个单行文字，实际 %d" % parts.size())
	for part in parts:
		ok(part is EntText, "拆解结果应为单行文字")

	# 序列化往返
	var d := e.to_dict()
	var r := EntMText.from_dict(d)
	ok(r.text == e.text, "文本往返")
	close(r.height, e.height, "字高往返")
	close(r.width, e.width, "字宽往返")
	close(r.line_spacing, e.line_spacing, "行距往返")
	ok(r.attach == e.attach, "对齐方式往返")
	ok(r.text_style == e.text_style, "文字样式往返")
	ok(r.layer == e.layer, "图层往返")
	# 折行结果必须一致（width_factor 也要往返）
	ok(r.layout_lines().size() == e.layout_lines().size(),
		"折行结果往返，%d vs %d" % [r.layout_lines().size(), e.layout_lines().size()])
	ok(r.get_annotation_texts().size() == e.get_annotation_texts().size(), "注记数量往返")
