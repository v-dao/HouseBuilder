class_name GbSheet
extends RefCounted
## 图纸幅面、图框、标题栏、会签栏（GB/T 50001—2017 第 3 章 + GB/T 10609.1）。
##
## 关键尺寸（单位 mm，均为图纸尺寸，与出图比例无关）：
##   · 基本幅面  A0 1189×841 / A1 841×594 / A2 594×420 / A3 420×297 / A4 297×210
##   · 加长幅面  长边按基本幅面短边的整数倍增加，如 A3×3 = 420×891
##   · 装订边 a  一律 25mm（留装订边的一侧）
##   · 其余边 c  A0、A1 取 10mm，A2~A4 取 5mm
##   · 标题栏    180×56，位于图框内右下角，长边与图纸长边平行
##   · 会签栏    100×20，横向图纸放在图框外左上角
##
## 图框按 **1:1 图纸尺寸**生成，因此应当放在图纸空间或按 1:1 出图使用；
## 若与 1:100 的平面图放在同一模型空间，需自行按比例放大。

## 基本幅面（长边, 短边）
const BASIC := {
	"A0": [1189.0, 841.0],
	"A1": [841.0, 594.0],
	"A2": [594.0, 420.0],
	"A3": [420.0, 297.0],
	"A4": [297.0, 210.0],
}

## 加长幅面：格式名 -> [基本幅面, 长边倍数]
const ELONGATED := {
	"A3X3": ["A3", 3], "A3X4": ["A3", 4], "A3X5": ["A3", 5],
	"A4X3": ["A4", 3], "A4X4": ["A4", 4], "A4X5": ["A4", 5],
	"A2X3": ["A2", 3], "A2X4": ["A2", 4],
	"A1X3": ["A1", 3],
	"A0X2": ["A0", 2],
}

## 装订边宽度 (mm)
const BINDING_MARGIN := 25.0

## 标题栏尺寸 (mm)
const TITLE_W := 180.0
const TITLE_H := 56.0

## 会签栏尺寸 (mm)
const SIGN_W := 100.0
const SIGN_H := 20.0


## 取幅面尺寸，返回 (长边, 短边)。未知名称返回 (0,0)。
static func sheet_size(format_name: String) -> Vector2:
	var n := format_name.strip_edges().to_upper()
	if BASIC.has(n):
		var b: Array = BASIC[n]
		return Vector2(float(b[0]), float(b[1]))
	if ELONGATED.has(n):
		var e: Array = ELONGATED[n]
		var base: Array = BASIC[String(e[0])]
		var k := float(e[1])
		# 加长幅面：短边不变，长边 = 短边 × 倍数
		var short_side := float(base[1])
		return Vector2(short_side * k, short_side)
	return Vector2.ZERO


## 图框在图纸上的内缩量。返回 [左, 下, 右, 上]（mm）。
## 装订边 25mm 放在左侧，其余边按幅面取 c。
static func margins(format_name: String) -> Array:
	var n := format_name.strip_edges().to_upper()
	var short_side := 297.0
	if BASIC.has(n):
		short_side = float((BASIC[n] as Array)[1])
	elif ELONGATED.has(n):
		var base: Array = BASIC[String((ELONGATED[n] as Array)[0])]
		short_side = float(base[1])
	# A0、A1 的其余边取 10mm，A2 及以下取 5mm
	var c := 10.0 if short_side >= 594.0 else 5.0
	return [BINDING_MARGIN, c, c, c]


## 可用图例名（供界面下拉）
static func format_names() -> Array[String]:
	var out: Array[String] = []
	for k in BASIC.keys():
		out.append(String(k))
	for k in ELONGATED.keys():
		out.append(String(k))
	return out


# ===========================================================================
# 图框生成
# ===========================================================================

## 在文档中生成图框 + 标题栏 + 会签栏。
## fields 支持的键：project / drawing / number / scale / design / draw /
##                  check / approve / date / sign
## 图框左下角位于原点，长边沿 X 轴。
static func build_frame(doc: CadDocument, format_name: String, portrait: bool,
		fields: Dictionary) -> bool:
	var size := sheet_size(format_name)
	if size.x <= 0.0:
		return false
	# 竖式：交换长短边
	var w := size.x
	var h := size.y
	if portrait:
		w = size.y
		h = size.x

	var frame_layer := _ensure_layer(doc, "图框", 1.0)
	var text_layer := _ensure_layer(doc, "文字", 0.25)

	var m := margins(format_name)
	var a := 25.0
	var c_left := a          # 装订边在左侧
	var c_other := float(m[1])

	# 幅面线（纸边）用细线，便于核对出图范围
	_add_rect(doc, frame_layer, 0.0, 0.0, w, h, 0.25)
	# 图框线用粗实线：左留 25mm 装订边，其余方向留 c
	var fx := c_left
	var fy := c_other
	var fw := w - c_left - c_other
	var fh := h - c_other * 2.0
	_add_rect(doc, frame_layer, fx, fy, fw, fh, 1.0)

	# 标题栏：图框内右下角，长边与图纸长边平行
	build_title_block(doc, fx + fw - TITLE_W, fy, fields, frame_layer, text_layer)

	# 会签栏（GB：设在图框外左上角）。
	# 上边距只有 5~10mm，放不下 20mm 高的会签栏，因此旋转 90° 后
	# 放进左侧的装订边里 —— 这正是国标把装订边留在左侧 25mm 的用意。
	build_sign_block_rotated(doc, c_other, h - c_other, frame_layer, text_layer,
		String(fields.get("sign", "")))

	return true


## 标题栏（GB/T 10609.1 常用格式，180×56）。
## 上排：工程名称 / 图名 / 图号；下排：设计 / 制图 / 校对 / 审核 / 比例。
static func build_title_block(doc: CadDocument, x: float, y: float, fields: Dictionary,
		frame_layer: String, text_layer: String) -> void:
	var total_w := TITLE_W
	var row1_h := 32.0
	var row2_h := TITLE_H - row1_h

	# 外框
	_add_rect(doc, frame_layer, x, y, total_w, TITLE_H, 1.0)
	# 横分隔
	_add_line(doc, frame_layer, Vector2(x, y + row2_h), Vector2(x + total_w, y + row2_h), 0.5)

	# 上排三格：工程名称 70、图名 70、图号 40
	var w1 := 70.0
	var w2 := 70.0
	var w3 := total_w - w1 - w2
	var split1 := x + w1
	var split2 := split1 + w2
	_add_line(doc, frame_layer, Vector2(split1, y + row2_h), Vector2(split1, y + TITLE_H), 0.5)
	_add_line(doc, frame_layer, Vector2(split2, y + row2_h), Vector2(split2, y + TITLE_H), 0.5)
	_put_text(doc, text_layer, Vector2(x + w1 * 0.5, y + row2_h + 18.0),
		String(fields.get("project", "")), 5.0, 1.0)
	# 图名用较大字高（GB：图名字高 7~10mm）
	_put_text(doc, text_layer, Vector2(split1 + w2 * 0.5, y + row2_h + 18.0),
		String(fields.get("drawing", "")), 7.0, 1.0)
	_put_text(doc, text_layer, Vector2(split2 + w3 * 0.5, y + row2_h + 18.0),
		String(fields.get("number", "")), 5.0, 1.0)

	# 下排五格：设计 / 制图 / 校对 / 审核 / 比例
	var labels := ["设计", "制图", "校对", "审核", "比例"]
	var keys := ["design", "draw", "check", "approve", "scale"]
	var cw := total_w / float(labels.size())
	for i in range(labels.size()):
		var cx := x + cw * float(i)
		if i > 0:
			_add_line(doc, frame_layer, Vector2(cx, y), Vector2(cx, y + row2_h), 0.5)
		# 格内左侧写字段名，右侧写值
		_put_text(doc, text_layer, Vector2(cx + 2.0, y + row2_h * 0.5), labels[i], 3.0, 0.0)
		_put_text(doc, text_layer, Vector2(cx + cw * 0.5 + 6.0, y + row2_h * 0.5),
			String(fields.get(keys[i], "")), 3.5, 0.0)


## 会签栏（旋转 90° 版）：放在左侧装订边内，文字自下而上阅读。
## 旋转后占用 20mm（宽）× 100mm（高），正好落在 25mm 的装订边里。
static func build_sign_block_rotated(doc: CadDocument, x: float, y_top: float,
		frame_layer: String, text_layer: String, sign_text: String) -> void:
	var majors := ["建筑", "结构", "给排水", "暖通", "电气"]
	var n := majors.size()
	var cell := SIGN_W / float(n)
	# 旋转后：块在图纸上占 x ~ x+SIGN_H，y_top-SIGN_W ~ y_top
	var x0 := x
	var x1 := x + SIGN_H
	var y0 := y_top - SIGN_W
	var y1 := y_top
	# 外框
	_add_line(doc, frame_layer, Vector2(x0, y0), Vector2(x1, y0), 0.5)
	_add_line(doc, frame_layer, Vector2(x1, y0), Vector2(x1, y1), 0.5)
	_add_line(doc, frame_layer, Vector2(x1, y1), Vector2(x0, y1), 0.5)
	_add_line(doc, frame_layer, Vector2(x0, y1), Vector2(x0, y0), 0.5)
	# "专业名"与"签名"的分隔线（旋转后是竖线）
	var xmid := x0 + SIGN_H * 0.5
	_add_line(doc, frame_layer, Vector2(xmid, y0), Vector2(xmid, y1), 0.25)
	for i in range(n):
		var cy := y0 + cell * float(i)
		if i > 0:
			_add_line(doc, frame_layer, Vector2(x0, cy), Vector2(x1, cy), 0.5)
		# 专业名在外侧（靠近纸边），签名在内侧
		_put_text_rot(doc, text_layer, Vector2(x0 + SIGN_H * 0.78, cy + cell * 0.5), majors[i])
		if sign_text != "":
			_put_text_rot(doc, text_layer, Vector2(x0 + SIGN_H * 0.24, cy + cell * 0.5), sign_text)


## 旋转 90° 的文字（自下而上阅读）
static func _put_text_rot(doc: CadDocument, layer: String, pos: Vector2, s: String) -> void:
	if s == "":
		return
	var t := EntText.make(pos, s, 3.0, PI * 0.5)
	t.layer = layer
	t.aci = 256
	t.text_style = "仿宋_3.5"
	t.h_align = EntText.HAlign.CENTER
	t.v_align = EntText.VAlign.MIDDLE
	doc.add_entity(t, false)


## 会签栏（100×20）。按建筑/结构/给排水/暖通/电气五个专业分格，各占一行签名位。
static func build_sign_block(doc: CadDocument, x: float, y: float,
		frame_layer: String, text_layer: String, sign_text: String) -> void:
	var majors := ["建筑", "结构", "给排水", "暖通", "电气"]
	var cw := SIGN_W / float(majors.size())
	_add_rect(doc, frame_layer, x, y, SIGN_W, SIGN_H, 0.5)
	# 中间横线分隔"专业名"与"签名"
	_add_line(doc, frame_layer, Vector2(x, y + SIGN_H * 0.5), Vector2(x + SIGN_W, y + SIGN_H * 0.5), 0.25)
	for i in range(majors.size()):
		var cx := x + cw * float(i)
		if i > 0:
			_add_line(doc, frame_layer, Vector2(cx, y), Vector2(cx, y + SIGN_H), 0.5)
		_put_text(doc, text_layer, Vector2(cx + cw * 0.5, y + SIGN_H * 0.75), majors[i], 3.0, 1.0)
		if sign_text != "":
			_put_text(doc, text_layer, Vector2(cx + cw * 0.5, y + SIGN_H * 0.25), sign_text, 3.0, 1.0)


# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------

static func _ensure_layer(doc: CadDocument, name: String, lw: float) -> String:
	var l := doc.ensure_layer(name)
	if l != null and l.lineweight < 0.0:
		l.lineweight = lw
	return name


static func _add_line(doc: CadDocument, layer: String, a: Vector2, b: Vector2, lw: float) -> void:
	var e := EntLine.make(a, b)
	e.layer = layer
	e.aci = 256
	e.lineweight = lw
	doc.add_entity(e, false)


static func _add_rect(doc: CadDocument, layer: String, x: float, y: float,
		w: float, h: float, lw: float) -> void:
	_add_line(doc, layer, Vector2(x, y), Vector2(x + w, y), lw)
	_add_line(doc, layer, Vector2(x + w, y), Vector2(x + w, y + h), lw)
	_add_line(doc, layer, Vector2(x + w, y + h), Vector2(x, y + h), lw)
	_add_line(doc, layer, Vector2(x, y + h), Vector2(x, y), lw)


## align: 0 = 左对齐（插入点为文字左端）, 1 = 居中对齐
static func _put_text(doc: CadDocument, layer: String, pos: Vector2, s: String,
		height: float, align: int) -> void:
	if s == "":
		return
	var t := EntText.make(pos, s, height)
	t.layer = layer
	t.aci = 256
	t.text_style = "标题栏_5" if height >= 5.0 else "仿宋_3.5"
	t.v_align = EntText.VAlign.MIDDLE
	t.h_align = EntText.HAlign.CENTER if align == 1 else EntText.HAlign.LEFT
	doc.add_entity(t, false)
