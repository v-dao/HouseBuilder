class_name EntText
extends CadEntity
## 单行文字。对应 DXF 的 TEXT。
##
## 国标 GB/T 50001—2017 规定：
##   · 字高取自 2.5 / 3.5 / 5 / 7 / 10 / 14 / 20 mm
##   · 汉字用长仿宋体，宽高比 0.7
##   · 字母数字可用 75° 斜体
## 字高与宽高比由 text_style 决定，本类只记录字高覆盖值。

## 水平对齐方式（对应 DXF 组码 72）
enum HAlign { LEFT, CENTER, RIGHT, ALIGNED, MIDDLE, FIT }
## 垂直对齐方式（对应 DXF 组码 73）
enum VAlign { BASELINE, BOTTOM, MIDDLE, TOP }

var position: Vector2 = Vector2.ZERO
var text: String = ""
## 字高 (mm)。为 0 时取文字样式的字高。
var height: float = 3.5
## 旋转角 (rad)
var rotation: float = 0.0
var text_style: String = "仿宋_3.5"
var h_align: int = HAlign.LEFT
var v_align: int = VAlign.BASELINE
## 宽高比覆盖值。<=0 表示使用文字样式的值。
var width_factor: float = -1.0
var oblique_angle: float = 0.0
## 由渲染器/字体模块实测的排版尺寸，用于拾取与包围盒
var measured_size: Vector2 = Vector2.ZERO
var measured_valid: bool = false


static func make(pos: Vector2, content: String, h := 3.5, rot := 0.0) -> EntText:
	var e := EntText.new()
	e.type = CadEntity.Type.TEXT
	e.position = pos
	e.text = content
	e.height = h
	e.rotation = rot
	return e


func type_name() -> String:
	return "文字"


## 文字没有解析曲线；渲染与拾取走专门的文字路径。
## 但基线作为一条退化曲线返回，便于捕捉插入点。
func _build_curves() -> Array[GeoCurve]:
	return []


## 把自身作为一条文字注记交给统一渲染路径
func get_annotation_texts() -> Array:
	return [{
		"text": text,
		"position": position,
		"rotation": rotation,
		"height": height,
		"style": text_style,
		"h_align": h_align,
		"v_align": v_align,
	}]


## 未实测时按字高与字符数估算包围盒，保证拾取在首次渲染前也可用。
## 汉字按 1 个字宽计，拉丁字母按 0.5 个字宽计。
func estimate_size() -> Vector2:
	var w := 0.0
	for i in range(text.length()):
		var cp := text.unicode_at(i)
		# CJK 统一表意文字与常用中文标点按全宽计
		if (cp >= 0x2E80 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFFEF):
			w += 1.0
		else:
			w += 0.5
	return Vector2(w * height * effective_width_factor(), height)


func effective_width_factor() -> float:
	if width_factor > 0.0:
		return width_factor
	return CadTextStyle.GB_ASPECT


func get_bbox() -> Rect2:
	var size := measured_size if measured_valid else estimate_size()
	# 局部坐标（基线在原点，文字向右上展开）
	var local := Transform2D(rotation, position)
	var corners := [
		local * Vector2(0, 0),
		local * Vector2(size.x, 0),
		local * Vector2(size.x, size.y),
		local * Vector2(0, size.y),
	]
	var mn: Vector2 = corners[0]
	var mx: Vector2 = corners[0]
	for c in corners:
		mn = Vector2(minf(mn.x, c.x), minf(mn.y, c.y))
		mx = Vector2(maxf(mx.x, c.x), maxf(mx.y, c.y))
	# 按对齐方式平移
	var off := _align_offset(size)
	mn += off
	mx += off
	return Rect2(mn, mx - mn)


## 对齐方式引起的局部偏移
func _align_offset(size: Vector2) -> Vector2:
	var dx := 0.0
	match h_align:
		HAlign.CENTER, HAlign.MIDDLE:
			dx = -size.x * 0.5
		HAlign.RIGHT:
			dx = -size.x
	var dy := 0.0
	match v_align:
		VAlign.TOP:
			dy = -size.y
		VAlign.MIDDLE:
			dy = -size.y * 0.5
	return Transform2D(rotation, Vector2.ZERO) * Vector2(dx, dy)


func get_grips() -> PackedVector2Array:
	return PackedVector2Array([position])


func move_grip(index: int, pos: Vector2) -> void:
	if index == 0:
		position = pos
	measured_valid = false
	invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	position = xf * position
	# 相似变换：字高按缩放比例调整，旋转角累加
	var scale := xf.x.length()
	if xf.determinant() < 0.0:
		# 镜像文字会变成反字，制图中无意义；仅翻转位置并保持可读
		scale = scale
	else:
		rotation += xf.get_rotation()
	height = maxf(height * scale, 0.1)
	measured_valid = false
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make(position, text, height, rotation)
	e.text_style = text_style
	e.h_align = h_align
	e.v_align = v_align
	e.width_factor = width_factor
	e.oblique_angle = oblique_angle
	_copy_base_to(e)
	return e


## 打散：文字转为多段线轮廓需要字体轮廓提取，留待后续（出图时用字形路径）。
func explode() -> Array[CadEntity]:
	return []


func set_measured_size(size: Vector2) -> void:
	measured_size = size
	measured_valid = true
	invalidate_bbox()


func to_dict() -> Dictionary:
	var d := super.to_dict()
	_put_v2(d, "position", position)
	d["text"] = text
	d["height"] = snappedf(height, 0.000001)
	d["rotation"] = snappedf(rotation, 1.0e-9)
	d["text_style"] = text_style
	d["h_align"] = h_align
	d["v_align"] = v_align
	if width_factor > 0.0:
		d["width_factor"] = snappedf(width_factor, 1.0e-6)
	if oblique_angle != 0.0:
		d["oblique_angle"] = snappedf(oblique_angle, 1.0e-9)
	return d


static func from_dict(d: Dictionary) -> EntText:
	var e := EntText.new()
	e.type = CadEntity.Type.TEXT
	e.read_base_fields(d)
	e.position = _v2(d, "position")
	e.text = String(d.get("text", ""))
	e.height = float(d.get("height", 3.5))
	e.rotation = float(d.get("rotation", 0.0))
	e.text_style = String(d.get("text_style", "仿宋_3.5"))
	e.h_align = int(d.get("h_align", HAlign.LEFT))
	e.v_align = int(d.get("v_align", VAlign.BASELINE))
	e.width_factor = float(d.get("width_factor", -1.0))
	e.oblique_angle = float(d.get("oblique_angle", 0.0))
	return e
