class_name P4Tests
extends TestSuite
## 块系统与内置建筑图库的测试。


func run() -> void:
	suite = "块：图库"
	_test_library_installed()
	_test_door_window_sizes()

	suite = "块：块引用"
	_test_insert_transform()
	_test_insert_scale_rotation()
	_test_insert_explode()
	_test_insert_attributes()

	suite = "块：定义与往返"
	_test_block_definition()
	_test_insert_roundtrip()


func _doc() -> CadDocument:
	var d := CadDocument.new()
	GbBlocks.install(d)
	return d


# ---------------------------------------------------------------------------
# 图库
# ---------------------------------------------------------------------------

func _test_library_installed() -> void:
	var doc := _doc()
	ok(doc.blocks.size() >= 25, "内置图库应有不少于 25 个块，实际 %d" % doc.blocks.size())
	var must := ["M0921", "M1021", "M1521", "C1215", "C1515", "C1815",
		"坐便器", "洗手盆", "浴缸", "灶台", "水槽", "冰箱",
		"双人床", "单人床", "三人沙发", "餐桌", "衣柜", "电视柜", "双跑楼梯"]
	for n in must:
		ok(doc.blocks.has(n), "图库应包含「%s」" % n)
	# 每个块都必须有图元，否则插入后是空的
	for k in doc.blocks.keys():
		var blk: CadBlock = doc.blocks[k]
		ok(blk.entities.size() >= 1, "块「%s」应至少有一个图元" % k)
		ok(blk.builtin, "内置块应标记 builtin，块「%s」" % k)
	# GbBlocks.block_names 与实际安装的块应一致
	var listed := GbBlocks.block_names()
	for n in listed:
		ok(doc.blocks.has(n), "block_names 列出的「%s」应已安装" % n)


## 门窗块的尺寸必须与编号一致：M0921 = 门 900 宽，C1515 = 窗 1500 宽。
## 这是国内设计院的编号约定，图库必须自洽。
func _test_door_window_sizes() -> void:
	var doc := _doc()
	var cases := {
		"M0921": Vector2(900.0, 2100.0),
		"M1021": Vector2(1000.0, 2100.0),
		"M1521": Vector2(1500.0, 2100.0),
		"C0912": Vector2(900.0, 1200.0),
		"C1215": Vector2(1200.0, 1500.0),
		"C1515": Vector2(1500.0, 1500.0),
		"C1815": Vector2(1800.0, 1500.0),
		"C2115": Vector2(2100.0, 1500.0),
	}
	for name in cases.keys():
		var blk := doc.get_block(String(name))
		if blk == null:
			ok(false, "缺少块 %s" % name)
			continue
		# 从编号里解析宽度与高度：M/C + 宽(2位) + 高(2位)，单位 100mm
		var code := String(name).substr(1)
		var w_expect := float(code.substr(0, 2).to_int()) * 100.0
		var h_expect := float(code.substr(2, 2).to_int()) * 100.0
		var exp: Vector2 = cases[name]
		close(w_expect, exp.x, "%s 编号中的宽度 = %.0f" % [name, exp.x], 1e-6)
		close(h_expect, exp.y, "%s 编号中的高度 = %.0f" % [name, exp.y], 1e-6)
		# 块的属性定义里应写明洞口尺寸，供门窗表提取
		var tags: Array[String] = []
		for a in blk.attribute_defs:
			tags.append(String((a as Dictionary).get("tag", "")))
		ok(tags.has("编号"), "%s 应有「编号」属性" % name)
		ok(tags.has("洞口宽"), "%s 应有「洞口宽」属性" % name)
		ok(tags.has("洞口高"), "%s 应有「洞口高」属性" % name)

		# 门扇与开启弧：门的几何尺寸应覆盖洞口宽度
		var bb := blk.get_bbox()
		ok(bb.size.x >= exp.x - 1.0, "%s 的几何宽度应不小于洞口宽，实际 %.0f" % [name, bb.size.x])


# ---------------------------------------------------------------------------
# 块引用
# ---------------------------------------------------------------------------

func _test_insert_transform() -> void:
	var doc := _doc()
	# M0921 的基点在 (0,0)，门扇沿 +X 长 900
	var blk := doc.get_block("M0921")
	var bb0 := blk.get_bbox()
	ok(absf(bb0.position.x) < 1.0, "门块基点的 x 应在 0 附近，实际 %.1f" % bb0.position.x)

	var ins := EntInsert.make("M0921", Vector2(5000.0, 3000.0))
	doc.add_entity(ins, false)
	var bb := ins.get_bbox()
	# 插入后几何应整体平移 (5000, 3000)
	close(bb.position.x, bb0.position.x + 5000.0, "插入后块包围盒 x 平移", 1e-3)
	close(bb.position.y, bb0.position.y + 3000.0, "插入后块包围盒 y 平移", 1e-3)
	close(bb.size.x, bb0.size.x, "未缩放时块尺寸不变", 1e-3)

	# get_curves 应返回变换后的曲线
	var cs := ins.get_curves()
	ok(cs.size() >= 4, "门块应展开出多条曲线，实际 %d" % cs.size())
	var mn := cs[0].bbox().position
	for c in cs:
		mn = Vector2(minf(mn.x, c.bbox().position.x), minf(mn.y, c.bbox().position.y))
	ok(mn.x >= 5000.0 - 1.0, "展开后的曲线应落在插入点附近，实际最小 x=%.1f" % mn.x)

	# 插入点应作为一个捕捉特征点
	var has_ins := false
	for f in ins.feature_points():
		if int(f["type"]) == SnapType.INSERTION:
			has_ins = true
	ok(has_ins, "块引用应提供插入点捕捉")


func _test_insert_scale_rotation() -> void:
	var doc := _doc()
	var base := doc.get_block("M0921").get_bbox()

	# 放大 2 倍
	var ins := EntInsert.make("M0921", Vector2.ZERO)
	ins.scale = Vector2(2.0, 2.0)
	doc.add_entity(ins, false)
	var bb := ins.get_bbox()
	close(bb.size.x, base.size.x * 2.0, "缩放 2 倍后宽度翻倍", 1e-2)
	close(bb.size.y, base.size.y * 2.0, "缩放 2 倍后高度翻倍", 1e-2)

	# 旋转 90°：宽高互换
	var ins2 := EntInsert.make("M0921", Vector2.ZERO)
	ins2.rotation = PI * 0.5
	doc.add_entity(ins2, false)
	var bb2 := ins2.get_bbox()
	close(bb2.size.x, base.size.y, "旋转 90° 后宽度等于原高度", 1e-2)
	close(bb2.size.y, base.size.x, "旋转 90° 后高度等于原宽度", 1e-2)


func _test_insert_explode() -> void:
	var doc := _doc()
	var blk := doc.get_block("C1515")
	var ins := EntInsert.make("C1515", Vector2(1000.0, 2000.0))
	ins.scale = Vector2(1.5, 1.5)
	ins.rotation = 0.4
	doc.add_entity(ins, false)

	var parts := ins.explode()
	ok(parts.size() >= blk.entities.size(), "拆解结果数应不少于块内图元数")
	# 拆解后的整体包围盒应与块引用一致
	var bb_ins := ins.get_bbox()
	var mn := parts[0].get_bbox().position
	var mx := parts[0].get_bbox().position + parts[0].get_bbox().size
	for i in range(1, parts.size()):
		var r := parts[i].get_bbox()
		mn = Vector2(minf(mn.x, r.position.x), minf(mn.y, r.position.y))
		mx = Vector2(maxf(mx.x, r.position.x + r.size.x), maxf(mx.y, r.position.y + r.size.y))
	var bb_exp := Rect2(mn, mx - mn)
	ok(bb_exp.position.distance_to(bb_ins.position) < 0.5,
		"拆解后的包围盒应与块引用一致，位置差 %.3f" % bb_exp.position.distance_to(bb_ins.position))
	ok(bb_exp.size.distance_to(bb_ins.size) < 0.5,
		"拆解后的包围盒尺寸应一致，差 %.3f" % bb_exp.size.distance_to(bb_ins.size))
	# 拆解出的图元不应带原块内的 handle
	for p in parts:
		ok(p.handle == 0, "拆解出的图元应重新分配 handle")


func _test_insert_attributes() -> void:
	var doc := _doc()
	var ins := EntInsert.make("M0921", Vector2.ZERO)
	doc.add_entity(ins, false)
	# 插入时的默认属性值由命令填入；这里直接验证替换逻辑
	ins.attributes["编号"] = "M5"
	ins.attributes["洞口宽"] = "1200"
	# 门窗块本身没有文字注记，属性是通过属性定义在门窗表里体现的，
	# 因此这里验证的是：块内若含与属性名同名的文字，会被替换
	var blk := doc.get_block("M0921")
	var t := EntText.make(Vector2(100, 100), "编号", 3.5)
	blk.add(t)
	var anns := ins.get_annotation_texts()
	var found := false
	for a in anns:
		if String(a["text"]) == "M5":
			found = true
	ok(found, "块内与属性名同名的文字应被替换为属性值")
	# 属性值数量应与属性定义一致
	ok(blk.attribute_defs.size() == 3, "门窗块应有 3 项属性定义（编号/洞口宽/洞口高）")


# ---------------------------------------------------------------------------
# 定义与往返
# ---------------------------------------------------------------------------

func _test_block_definition() -> void:
	var doc := CadDocument.new()
	# 手工构造一个块定义，验证 block 内图元的坐标相对基点
	var blk := CadBlock.make("测试块", Vector2(1000.0, 1000.0))
	var l := EntLine.make(Vector2(1000.0, 1000.0), Vector2(2000.0, 1000.0))
	blk.add(l)
	doc.blocks["测试块"] = blk
	ok(l.owner_block == "测试块", "加入块后图元应记录所属块名")

	var ins := EntInsert.make("测试块", Vector2(5000.0, 5000.0))
	doc.add_entity(ins, false)
	# 基点 (1000,1000) 应映射到插入点 (5000,5000)，故线从 (5000,5000) 到 (6000,5000)
	var cs := ins.get_curves()
	ok(cs.size() == 1, "应展开出 1 条曲线")
	if cs.size() == 1:
		var sg := cs[0] as GeoSeg
		vclose(sg.a, Vector2(5000.0, 5000.0), "基点应映射到插入点", 1e-3)
		vclose(sg.b, Vector2(6000.0, 5000.0), "块内图元应随基点平移", 1e-3)

	# 块缺失时不应崩溃
	var orphan := EntInsert.make("不存在的块", Vector2.ZERO)
	doc.add_entity(orphan, false)
	ok(orphan.get_curves().is_empty(), "块缺失时应返回空曲线")
	ok(orphan.explode().is_empty(), "块缺失时拆解应为空")


func _test_insert_roundtrip() -> void:
	var doc := _doc()
	var ins := EntInsert.make("C1815", Vector2(1234.0, 5678.0))
	ins.scale = Vector2(1.25, 1.25)
	ins.rotation = 0.7
	ins.attributes["编号"] = "C9"
	ins.layer = "门窗"
	ins.aci = 0
	doc.add_entity(ins, false)

	var d := ins.to_dict()
	var r := EntInsert.from_dict(d)
	# 块引用必须加入文档才能解析到块定义（get_block 依赖所属文档），
	# 否则包围盒退化为插入点本身。
	doc.add_entity(r, false)
	ok(r.block_name == ins.block_name, "块名往返")
	vclose(r.position, ins.position, "插入点往返", 1e-6)
	vclose(r.scale, ins.scale, "缩放往返", 1e-9)
	close(r.rotation, ins.rotation, "旋转往返", 1e-9)
	ok(String(r.attributes.get("编号", "")) == "C9", "属性值往返")
	ok(r.layer == ins.layer, "图层往返")

	# 展开后的几何必须一致
	var a := ins.get_bbox()
	var b := r.get_bbox()
	ok(a.position.distance_to(b.position) < 1e-2 and a.size.distance_to(b.size) < 1e-2,
		"包围盒往返 (%.2f,%.2f)+/-(%.2f,%.2f) vs (%.2f,%.2f)+/-(%.2f,%.2f)" % [
			a.position.x, a.position.y, a.size.x, a.size.y,
			b.position.x, b.position.y, b.size.x, b.size.y])
	ok(r.get_curves().size() == ins.get_curves().size(), "展开曲线数往返")
