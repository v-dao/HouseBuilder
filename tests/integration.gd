extends SceneTree
## 集成检查：从示例图一路走到批量出图，覆盖审计后新补的命令。
## 与单元测试的分工：单元测试验每个函数，这里验它们串起来能跑通。
## 运行：godot --headless --path <项目> --script res://tests/integration.gd

func _initialize() -> void:
	var doc := CadDocument.new()
	GbBlocks.install(doc)
	DemoDrawing.build(doc)
	print("图元数 = ", doc.entity_count())

	# 建立两个布局，模拟"平面图 + 详图"两张图纸
	var l1: CadLayout = doc.ensure_layout("一层平面图")
	l1.title_fields = {"project": "某住宅小区 1# 楼", "drawing": "一层平面图",
		"number": "建施-05", "scale": "1:100"}
	l1.fit_model_to_paper(doc.get_bbox())
	var l2 := CadLayout.make("节点详图", "A4", false)
	l2.title_fields = {"drawing": "外墙保温节点", "number": "建施-12", "scale": "1:10"}
	l2.main_viewport().scale = 10.0
	l2.main_viewport().model_center = Vector2(3000, 3000)
	doc.layouts.append(l2)
	print("布局数 = ", doc.layouts.size())

	# 图纸目录与材料做法表
	var ctx := CommandContext.new()
	ctx.doc = doc
	var sl := CmdTables.SheetList.new()
	sl.ctx = ctx
	sl.start({})
	sl.on_point(Vector2(-14000, 9000))
	var mt := CmdTables.MaterialTable.new()
	mt.ctx = ctx
	mt.start({})
	mt.on_point(Vector2(-14000, 3000))
	print("生成表格后图元数 = ", doc.entity_count())

	# 快速选择：按类型筛墙体
	var qs := CmdTables.QuickSelect.new()
	qs.ctx = ctx
	qs.start({})
	qs.on_text("墙体")
	qs.on_text("")
	print("快速选择：", qs.on_text(""))

	# 批量出图：每个布局一个 PDF
	var dir := "res://tests/out/batch"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var font := OS.get_system_font_path("FangSong", 400, 100, false)
	var made := 0
	for i in range(doc.layouts.size()):
		var lay: CadLayout = doc.layouts[i]
		var w := PdfWriter.new()
		w.layout = lay
		if font != "":
			w.set_font(font)
		var no := String(lay.title_fields.get("number", ""))
		var nm := String(lay.title_fields.get("drawing", lay.name))
		var f := "%s/%s_%s.pdf" % [dir, no, nm]
		if w.save(doc, f) == OK:
			made += 1
			var fh := FileAccess.open(f, FileAccess.READ)
			print("  出图 %s -> %.2f MB" % [f.get_file(), fh.get_length() / 1048576.0])
			fh.close()
	print("批量出图成功 ", made, " 个")

	# 模数校验
	print("模数：3600 是 300 的倍数 = ", GbModular.is_module(3600.0, 300.0))
	print("  3610 -> 最近合规值 ", GbModular.snap_to_module(3610.0, 100.0))
	print("  240 墙厚在常用序列中 = ", GbModular.validate_all(240.0, "墙厚", GbModular.WALL_THICKNESSES) == "")
	print("  250 墙厚：", GbModular.validate_all(250.0, "墙厚", GbModular.WALL_THICKNESSES))
	quit(0)
