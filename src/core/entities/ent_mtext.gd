class_name EntMText
extends CadEntity
## 多行文字。对应 DXF 的 MTEXT。
##
## 与单行文字（EntText）的区别：
##   · 支持段落（换行符分隔）与自动换行（给定字宽后按字宽折行）
##   · 支持九种对齐方式（左上/中上/右上/左中/正中/右中/左下/中下/右下）
##   · 行距可调
##
## 换行按**字宽单位**计算而不查字体度量：
## 长仿宋是等宽的（汉字 1.0 字宽、拉丁字母数字约 0.5 字宽），
## 按字宽单位折行的结果与真实排版几乎一致，
## 同时让本类不依赖 FontManager（避免 core 反向依赖 render）。

## 九种对齐方式，与 DXF 组码 71 的取值一致
enum Attach {
	TOP_LEFT, TOP_CENTER, TOP_RIGHT,
	MIDDLE_LEFT, MIDDLE_CENTER, MIDDLE_RIGHT,
	BOTTOM_LEFT, BOTTOM_CENTER, BOTTOM_RIGHT,
}

var position: Vector2 = Vector2.ZERO
## 段落文本，用 \n 分隔
var text: String = ""
## 字高 (mm)
var height: float = 3.5
## 自动换行的字宽 (mm)。<= 0 表示不自动换行。
var width: float = 0.0
var rotation: float = 0.0
var text_style: String = "仿宋_3.5"
var attach: int = Attach.TOP_LEFT
## 行距系数（相对字高）
var line_spacing: float = 1.5
## 宽高比覆盖值。<=0 表示用文字样式的值。
var width_factor: float = -1.0
## 实测尺寸（渲染器回写），用于包围盒与拾取
var measured_size: Vector2 = Vector2.ZERO
var measured_valid: bool = false


static func make(pos: Vector2, content: String, h := 3.5) -> EntMText:
	var e := EntMText.new()
	e.type = CadEntity.Type.MTEXT
	e.position = pos
	e.text = content
	e.height = h
	return e


func type_name() -> String:
	return "多行文字"


## 单个字符占几个字宽：汉字与中文标点算 1，拉丁字母数字算 0.5
static func char_units(cp: int) -> float:
	if (cp >= 0x2E80 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF) \
			or (cp >= 0xFF00 and cp <= 0xFFEF) or (cp >= 0x3000 and cp <= 0x303F):
		return 1.0
	return 0.5


static func string_units(s: String) -> float:
	var w := 0.0
	for i in range(s.length()):
		w += char_units(s.unicode_at(i))
	return w


func effective_width_factor() -> float:
	if width_factor > 0.0:
		return width_factor
	return CadTextStyle.GB_ASPECT


## 按字宽折行后的各行文本
func layout_lines() -> Array[String]:
	var out: Array[String] = []
	var paragraphs := text.split("\n")
	if width <= 0.0:
		for p in paragraphs:
			out.append(p)
		return out
	var max_units := width / maxf(height * effective_width_factor(), 1.0e-6)
	for para in paragraphs:
		if para == "":
			out.append("")
			continue
		var line := ""
		var acc := 0.0
		for i in range(para.length()):
			var ch := para.substr(i, 1)
			var u := char_units(para.unicode_at(i))
			if acc + u > max_units and line != "":
				out.append(line)
				line = ch
				acc = u
			else:
				line += ch
				acc += u
		out.append(line)
	return out


## 每行的字宽单位数，用于算行宽
func _line_units(s: String) -> float:
	return string_units(s)


## 整块文字在**局部坐标系**下的尺寸（宽, 高）
func block_size() -> Vector2:
	var lines := layout_lines()
	var max_u := 0.0
	for l in lines:
		max_u = maxf(max_u, _line_units(l))
	var w := max_u * height * effective_width_factor()
	var n := maxi(lines.size(), 1)
	var h := height + float(n - 1) * height * line_spacing
	return Vector2(w, h)


## 第一行文字中心的局部偏移。
##
## 局部坐标系：以插入点为原点，X 向右、Y 向下（与屏幕一致，渲染器可直接使用）。
## 每行按 CENTER 水平居中绘制，所以 dx 指向"该行的中心"而非块边缘：
##   左对齐 -> 块左边缘在原点，行中心在 +size.x/2
##   居中   -> 块中心在原点，行中心在 0
##   右对齐 -> 块右边缘在原点，行中心在 -size.x/2
func _attach_offset(size: Vector2) -> Vector2:
	var col := attach % 3
	var row := attach / 3
	var dx := 0.0
	match col:
		0:
			dx = size.x * 0.5
		1:
			dx = 0.0
		2:
			dx = -size.x * 0.5
	var dy := 0.0
	match row:
		0:
			dy = height * 0.5                     # 上边缘在原点
		1:
			dy = -size.y * 0.5 + height * 0.5     # 垂直居中
		2:
			dy = -size.y + height * 0.5           # 下边缘在原点
	return Vector2(dx, dy)


func _build_curves() -> Array[GeoCurve]:
	return []


## 逐行输出文字注记。渲染器按条绘制，因此多行文字天然支持任意对齐与旋转。
func get_annotation_texts() -> Array:
	var lines := layout_lines()
	if lines.is_empty():
		return []
	var size := block_size()
	var off := _attach_offset(size)
	# 局部坐标系以插入点为原点、X 向右、Y 向下（与屏幕一致，便于渲染器直接使用）
	var xf := Transform2D(rotation, Vector2.ZERO)
	var out: Array = []
	var lead := height * line_spacing
	for i in range(lines.size()):
		var line := lines[i]
		if line == "":
			continue
		var local := Vector2(off.x, off.y + float(i) * lead)
		out.append({
			"text": line,
			"position": position + xf * local,
			"rotation": rotation,
			"height": height,
			"style": text_style,
			"h_align": EntText.HAlign.CENTER,
			# 上下居中于该行的行高中心
			"v_align": EntText.VAlign.MIDDLE,
		})
	return out


func get_bbox() -> Rect2:
	var lines := layout_lines()
	if lines.is_empty():
		return Rect2(position, Vector2.ZERO)
	var size := block_size()
	var off := _attach_offset(size)
	var xf := Transform2D(rotation, position)
	var corners := [
		xf * off,
		xf * (off + Vector2(size.x, 0)),
		xf * (off + size),
		xf * (off + Vector2(0, size.y)),
	]
	var mn: Vector2 = corners[0]
	var mx: Vector2 = corners[0]
	for c in corners:
		mn = Vector2(minf(mn.x, c.x), minf(mn.y, c.y))
		mx = Vector2(maxf(mx.x, c.x), maxf(mx.y, c.y))
	return Rect2(mn, mx - mn)


func get_grips() -> PackedVector2Array:
	return PackedVector2Array([position])


func get_stretch_points() -> PackedVector2Array:
	return PackedVector2Array([position])


func move_grip(_i: int, p: Vector2) -> void:
	position = p
	invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	position = xf * position
	var scale := xf.x.length()
	if xf.determinant() >= 0.0:
		rotation += xf.get_rotation()
	height = maxf(height * scale, 0.05)
	# 字宽随字高同比缩放，保持折行结果不变
	if width > 0.0:
		width *= scale
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make(position, text, height)
	e.width = width
	e.rotation = rotation
	e.text_style = text_style
	e.attach = attach
	e.line_spacing = line_spacing
	e.width_factor = width_factor
	_copy_base_to(e)
	return e


## 打散：每一行成为一条单行文字
func explode() -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	for a in get_annotation_texts():
		var t := EntText.make(a["position"], String(a["text"]), float(a["height"]), float(a["rotation"]))
		t.text_style = String(a["style"])
		t.h_align = int(a["h_align"])
		t.v_align = int(a["v_align"])
		_copy_base_to(t)
		out.append(t)
	return out


func to_dict() -> Dictionary:
	var d := super.to_dict()
	_put_v2(d, "position", position)
	d["text"] = text
	d["height"] = snappedf(height, 1e-6)
	d["width"] = snappedf(width, 1e-6)
	d["rotation"] = snappedf(rotation, 1e-9)
	d["text_style"] = text_style
	d["attach"] = attach
	d["line_spacing"] = snappedf(line_spacing, 1e-6)
	if width_factor > 0.0:
		d["width_factor"] = snappedf(width_factor, 1e-6)
	return d


static func from_dict(d: Dictionary) -> EntMText:
	var e := EntMText.new()
	e.type = CadEntity.Type.MTEXT
	e.read_base_fields(d)
	e.position = _v2(d, "position")
	e.text = String(d.get("text", ""))
	e.height = float(d.get("height", 3.5))
	e.width = float(d.get("width", 0.0))
	e.rotation = float(d.get("rotation", 0.0))
	e.text_style = String(d.get("text_style", "仿宋_3.5"))
	e.attach = int(d.get("attach", Attach.TOP_LEFT))
	e.line_spacing = float(d.get("line_spacing", 1.5))
	e.width_factor = float(d.get("width_factor", -1.0))
	return e
