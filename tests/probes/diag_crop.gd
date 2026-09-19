extends Node
## 把 _app.png 里客厅附近那点可疑的黄色放大裁出来，确认是不是真的有多余的图元。

const SRC := "res://tests/out/_app.png"
const ZOOM := 5


func _ready() -> void:
	var img := Image.load_from_file(ProjectSettings.globalize_path(SRC))
	if img == null:
		print("读不到 ", SRC)
		get_tree().quit(1)
		return
	var spots := [Vector2(650.0, 455.0), Vector2(640.0, 490.0)]
	var half := Vector2i(60, 40)
	var w := half.x * 2 * ZOOM
	var h := half.y * 2 * ZOOM
	var out := Image.create(w * spots.size(), h, false, img.get_format())
	for k in range(spots.size()):
		var s: Vector2 = spots[k]
		print("裁 %s 附近 %dx%d @%dx" % [str(s), half.x * 2, half.y * 2, ZOOM])
		for y in range(h):
			for x in range(w):
				var sx := int(s.x) - half.x + x / ZOOM
				var sy := int(s.y) - half.y + y / ZOOM
				if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
					continue
				out.set_pixel(k * w + x, y, img.get_pixel(sx, sy))
	out.save_png("res://tests/out/_app_zoom.png")
	print("已写出 res://tests/out/_app_zoom.png")
	get_tree().quit(0)
