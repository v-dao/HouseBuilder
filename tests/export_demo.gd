extends SceneTree
## 把示例图导出为 DXF，供 ezdxf 做独立校验。

func _initialize() -> void:
	var doc := CadDocument.new()
	GbBlocks.install(doc)
	DemoDrawing.build(doc)
	print("图元数 = ", doc.entity_count())
	var w := DxfWriter.new(doc)
	var err := w.save("res://tests/out/demo.dxf")
	print("导出 DXF 错误码 = ", err)
	var f := FileAccess.open("res://tests/out/demo.dxf", FileAccess.READ)
	if f != null:
		print("文件大小 = %.1f KB" % (f.get_length() / 1024.0))
		f.close()
	# 顺带导出 SVG 供目视核对
	var sw := SvgWriter.new(doc.plot_scale)
	var svg := sw.write(doc)
	var sf := FileAccess.open("res://tests/out/demo.svg", FileAccess.WRITE)
	sf.store_string(svg)
	sf.close()
	print("SVG 大小 = %.1f KB" % (svg.length() / 1024.0))
	quit(0)
