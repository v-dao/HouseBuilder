extends SceneTree
## 导出 PDF 供外部校验

func _initialize() -> void:
	var doc := CadDocument.new()
	GbBlocks.install(doc)
	DemoDrawing.build(doc)
	var w := PdfWriter.new()
	var font := OS.get_system_font_path("FangSong", 400, 100, false)
	print("字体路径 = ", font)
	print("字体载入 = ", w.set_font(font))
	var err := w.save(doc, "res://tests/out/demo.pdf")
	print("导出错误码 = ", err)
	var f := FileAccess.open("res://tests/out/demo.pdf", FileAccess.READ)
	if f != null:
		print("PDF 大小 = %.2f MB" % (f.get_length() / 1048576.0))
		f.close()
	quit(0)
