class_name EntSymbols
extends RefCounted
## 国标符号图元族。
##
## 这一族图元的共同点：几何完全由**位置 + 参数 + 出图比例**推导，
## 与尺寸标注同源。国标里它们的尺寸都以"图纸上的毫米"给出，
## 因此所有尺寸都要乘 plot_scale 才能落到模型空间。
##
## 七个符号（GB/T 50001—2017 第 9、10 章）：
##   标高符号      直角等腰三角形，高约 3mm；标高数字以米为单位、三位小数，零点注成 ±0.000
##   索引符号      直径 10mm 细实线圆 + 水平直径；上半圆写详图编号、下半圆写图纸编号
##   详图符号      直径 14mm 粗实线圆 + 水平直径；与被索引的详图对应
##   剖切符号      剖切位置线（长 6~10mm 粗实线）+ 投射方向线（长 4~6mm 粗实线）
##   引出线        细实线，文字注写在水平线上方或端部
##   折断线        细实线；直线折断画成 Z 字形，曲线折断用波浪线
##   轴线号        细实线圆，直径 8~10mm，内注轴线编号

enum Kind { ELEVATION, INDEX, DETAIL, SECTION, LEADER, BREAK_LINE, AXIS_BUBBLE }


## 符号基类
class Base extends CadEntity:
	var kind: int = -1

	func _init() -> void:
		type = CadEntity.Type.SYMBOL

	## 图纸毫米 -> 模型毫米
	func mm(v: float) -> float:
		return v * plot_scale()

	func kind_name() -> String:
		return "符号"


# ===========================================================================
# 标高符号
# ===========================================================================

class Elevation extends Base:
	## 三角形尖端所指的位置（即被标注的面）
	var position: Vector2 = Vector2.ZERO
	## 标高值，单位 mm。0 显示为 ±0.000
	var elevation: float = 0.0
	## true 时符号朝上（用于标注低于本层的标高，如基础底、地沟底）
	var flip: bool = false

	static func make(pos: Vector2, elev_mm: float, is_flip := false) -> Elevation:
		var e := Elevation.new()
		e.kind = Kind.ELEVATION
		e.position = pos
		e.elevation = elev_mm
		e.flip = is_flip
		return e

	func kind_name() -> String:
		return "标高符号"

	## GB：直角等腰三角形，高约 3mm，用细实线绘制
	func _build_curves() -> Array[GeoCurve]:
		var h := mm(3.0)
		var sgn := -1.0 if flip else 1.0
		var apex := position
		var left := position + Vector2(-h, h * sgn)
		var right := position + Vector2(h, h * sgn)
		return [
			GeoSeg.make(left, right),
			GeoSeg.make(left, apex),
			GeoSeg.make(apex, right),
		]

	## 标高数字：以米为单位，注写到小数点后三位；零点注成 ±0.000。
	## GB 规定正数不带 + 号，负数带 - 号。
	static func format_elevation(mm_value: float) -> String:
		if absf(mm_value) < 0.5:
			return "±0.000"
		return "%.3f" % (mm_value / 1000.0)

	func get_annotation_texts() -> Array:
		var h := mm(3.0)
		var sgn := -1.0 if flip else 1.0
		# 文字在三角形外侧，与底边留一点间隙
		var pos := position + Vector2(0.0, (h + mm(1.5)) * sgn)
		return [{
			"text": format_elevation(elevation),
			"position": pos,
			"rotation": 0.0,
			"height": mm(2.5),
			"style": "标注_2.5",
			# 朝下（flip=false）时文字在三角形上方，故用 BOTTOM 对齐
			"h_align": EntText.HAlign.CENTER,
			"v_align": EntText.VAlign.TOP if flip else EntText.VAlign.BOTTOM,
		}]

	func get_grips() -> PackedVector2Array:
		return PackedVector2Array([position])

	func move_grip(_i: int, p: Vector2) -> void:
		position = p
		invalidate_bbox()

	func transform_by(xf: Transform2D) -> void:
		position = xf * position
		# 标高值按缩放比例调整（拉大图时标高不应变，但整体缩放的语义是几何缩放）
		# 这里保持标高数值不变更符合工程直觉：标高是属性而非几何。
		invalidate_bbox()

	func clone() -> CadEntity:
		var c := Elevation.make(position, elevation, flip)
		_copy_base_to(c)
		return c

	func to_dict() -> Dictionary:
		var d := super.to_dict()
		d["kind"] = Kind.ELEVATION
		_put_v2(d, "position", position)
		d["elevation"] = snappedf(elevation, 0.001)
		d["flip"] = flip
		return d


# ===========================================================================
# 索引符号 / 详图符号
# ===========================================================================

class IndexMark extends Base:
	## 圆心位置
	var position: Vector2 = Vector2.ZERO
	## 上半圆编号（详图编号）
	var top_text: String = "1"
	## 下半圆编号（图纸编号）；详图符号时可为空
	var bottom_text: String = ""
	## true 为详图符号（直径 14mm 粗圆），false 为索引符号（直径 10mm 细圆）
	var is_detail: bool = false
	## 索引符号的水平直径可延长出引线，指向被索引部位
	var leader_to: Vector2 = Vector2.ZERO
	var has_leader: bool = false

	static func make_index(pos: Vector2, detail_no: String, sheet_no: String) -> IndexMark:
		var m := IndexMark.new()
		m.kind = Kind.INDEX
		m.position = pos
		m.top_text = detail_no
		m.bottom_text = sheet_no
		m.is_detail = false
		return m

	static func make_detail(pos: Vector2, detail_no: String, sheet_no := "") -> IndexMark:
		var m := IndexMark.new()
		m.kind = Kind.DETAIL
		m.position = pos
		m.top_text = detail_no
		m.bottom_text = sheet_no
		m.is_detail = true
		return m

	func kind_name() -> String:
		return "详图符号" if is_detail else "索引符号"

	func radius() -> float:
		# 索引符号直径 10mm、详图符号直径 14mm
		return mm(7.0 if is_detail else 5.0)

	func _build_curves() -> Array[GeoCurve]:
		var out: Array[GeoCurve] = []
		var r := radius()
		out.append(GeoArc.make_circle(position, r))
		# 水平直径
		out.append(GeoSeg.make(position - Vector2(r, 0), position + Vector2(r, 0)))
		if has_leader:
			out.append(GeoSeg.make(position + Vector2(r, 0), leader_to))
		return out

	## 上下半圆的编号：文字紧贴水平直径的上下方
	func get_annotation_texts() -> Array:
		var r := radius()
		var out: Array = []
		if top_text != "":
			out.append({
				"text": top_text,
				"position": position + Vector2(0.0, r * 0.18),
				"rotation": 0.0,
				"height": mm(3.5),
				"style": "标注_2.5",
				"h_align": EntText.HAlign.CENTER,
				"v_align": EntText.VAlign.BOTTOM,
			})
		if bottom_text != "":
			out.append({
				"text": bottom_text,
				"position": position - Vector2(0.0, r * 0.18),
				"rotation": 0.0,
				"height": mm(3.5),
				"style": "标注_2.5",
				"h_align": EntText.HAlign.CENTER,
				"v_align": EntText.VAlign.TOP,
			})
		return out

	func get_grips() -> PackedVector2Array:
		var g := PackedVector2Array([position])
		if has_leader:
			g.append(leader_to)
		return g

	func move_grip(i: int, p: Vector2) -> void:
		if i == 0:
			position = p
		elif i == 1:
			leader_to = p
			has_leader = true
		invalidate_bbox()

	func transform_by(xf: Transform2D) -> void:
		position = xf * position
		leader_to = xf * leader_to
		invalidate_bbox()

	func clone() -> CadEntity:
		var c := IndexMark.new()
		c.kind = kind
		c.position = position
		c.top_text = top_text
		c.bottom_text = bottom_text
		c.is_detail = is_detail
		c.leader_to = leader_to
		c.has_leader = has_leader
		_copy_base_to(c)
		return c

	func to_dict() -> Dictionary:
		var d := super.to_dict()
		d["kind"] = Kind.DETAIL if is_detail else Kind.INDEX
		_put_v2(d, "position", position)
		d["top_text"] = top_text
		d["bottom_text"] = bottom_text
		d["is_detail"] = is_detail
		if has_leader:
			_put_v2(d, "leader_to", leader_to)
			d["has_leader"] = true
		return d


# ===========================================================================
# 剖切符号
# ===========================================================================

class SectionMark extends Base:
	## 剖切位置线的两端
	var p1: Vector2 = Vector2.ZERO
	var p2: Vector2 = Vector2.ZERO
	## 投射方向：相对于 p1->p2 的左右侧，+1 为左侧、-1 为右侧
	var side: int = 1
	## 编号（阿拉伯数字或大写字母）
	var number: String = "1"

	static func make(a: Vector2, b: Vector2, dir_side := 1, no := "1") -> SectionMark:
		var m := SectionMark.new()
		m.kind = Kind.SECTION
		m.p1 = a
		m.p2 = b
		m.side = dir_side
		m.number = no
		return m

	func kind_name() -> String:
		return "剖切符号"

	## 剖切位置线长 6~10mm，投射方向线长 4~6mm（GB/T 50001 第 9 章）
	func _build_curves() -> Array[GeoCurve]:
		var out: Array[GeoCurve] = []
		var d := p2 - p1
		if d.length() <= Tol.MIN_LEN:
			return out
		var u := d.normalized()
		var n := Vector2(-u.y, u.x) * float(side)
		# 剖切位置线：p1 到 p2
		out.append(GeoSeg.make(p1, p2))
		# 两端各画一条投射方向线，指向观察方向
		var dir_len := mm(5.0)
		out.append(GeoSeg.make(p1, p1 + n * dir_len))
		out.append(GeoSeg.make(p2, p2 + n * dir_len))
		return out

	## 编号写在投射方向线的端部
	func get_annotation_texts() -> Array:
		var d := p2 - p1
		if d.length() <= Tol.MIN_LEN:
			return []
		var u := d.normalized()
		var n := Vector2(-u.y, u.x) * float(side)
		var off := n * mm(5.0 + 1.5)
		var ang := 0.0 if absf(u.x) >= absf(u.y) else PI * 0.5
		return [
			{
				"text": number, "position": p1 + off, "rotation": ang,
				"height": mm(3.5), "style": "图名_7",
				"h_align": EntText.HAlign.CENTER, "v_align": EntText.VAlign.MIDDLE,
			},
			{
				"text": number, "position": p2 + off, "rotation": ang,
				"height": mm(3.5), "style": "图名_7",
				"h_align": EntText.HAlign.CENTER, "v_align": EntText.VAlign.MIDDLE,
			},
		]

	func get_grips() -> PackedVector2Array:
		return PackedVector2Array([p1, p2])

	func move_grip(i: int, p: Vector2) -> void:
		if i == 0:
			p1 = p
		elif i == 1:
			p2 = p
		invalidate_bbox()

	func transform_by(xf: Transform2D) -> void:
		p1 = xf * p1
		p2 = xf * p2
		invalidate_bbox()

	func clone() -> CadEntity:
		var c := SectionMark.make(p1, p2, side, number)
		_copy_base_to(c)
		return c

	func to_dict() -> Dictionary:
		var d := super.to_dict()
		d["kind"] = Kind.SECTION
		_put_v2(d, "p1", p1)
		_put_v2(d, "p2", p2)
		d["side"] = side
		d["number"] = number
		return d


# ===========================================================================
# 引出线
# ===========================================================================

class Leader extends Base:
	## 折线顶点：首点在标注对象上，末点在文字侧
	var points: PackedVector2Array = PackedVector2Array()
	var text: String = ""
	## 首端的箭头（指向被标注对象）
	var arrow: bool = true

	static func make(pts: PackedVector2Array, label: String) -> Leader:
		var l := Leader.new()
		l.kind = Kind.LEADER
		l.points = pts
		l.text = label
		return l

	func kind_name() -> String:
		return "引出线"

	func _build_curves() -> Array[GeoCurve]:
		var out: Array[GeoCurve] = []
		for i in range(points.size() - 1):
			out.append(GeoSeg.make(points[i], points[i + 1]))
		if arrow and points.size() >= 2:
			# 箭头指向首点（被标注对象）
			var tip := points[0]
			var dir := (points[0] - points[1])
			if dir.length() > Tol.MIN_LEN:
				var u := dir.normalized()
				var a := mm(3.0)
				var n := Vector2(-u.y, u.x) * a * 0.3
				var back := tip + u * a
				out.append(GeoSeg.make(tip, back + n))
				out.append(GeoSeg.make(tip, back - n))
				out.append(GeoSeg.make(back + n, back - n))
		return out

	## 文字注写在末点的端部（GB：注写在水平线的上方或端部）
	func get_annotation_texts() -> Array:
		if text == "" or points.is_empty():
			return []
		var end := points[points.size() - 1]
		var ang := 0.0
		if points.size() >= 2:
			var d := end - points[points.size() - 2]
			if absf(d.x) >= absf(d.y):
				ang = 0.0
			else:
				ang = PI * 0.5
		return [{
			"text": text,
			"position": end,
			"rotation": ang,
			"height": mm(3.5),
			"style": "仿宋_3.5",
			"h_align": EntText.HAlign.LEFT,
			"v_align": EntText.VAlign.BOTTOM,
		}]

	func get_grips() -> PackedVector2Array:
		return points.duplicate()

	func move_grip(i: int, p: Vector2) -> void:
		if i >= 0 and i < points.size():
			points[i] = p
		invalidate_bbox()

	func transform_by(xf: Transform2D) -> void:
		for i in range(points.size()):
			points[i] = xf * points[i]
		invalidate_bbox()

	func clone() -> CadEntity:
		var c := Leader.make(points.duplicate(), text)
		c.arrow = arrow
		_copy_base_to(c)
		return c

	func to_dict() -> Dictionary:
		var d := super.to_dict()
		d["kind"] = Kind.LEADER
		d["points"] = _pts_to_arr(points)
		d["text"] = text
		d["arrow"] = arrow
		return d


# ===========================================================================
# 折断线 / 波浪线
# ===========================================================================

class BreakLine extends Base:
	enum Style { STRAIGHT, WAVY }
	var style: int = Style.STRAIGHT
	var p1: Vector2 = Vector2.ZERO
	var p2: Vector2 = Vector2.ZERO
	## 波浪的幅度（图纸毫米）
	var amplitude_mm: float = 1.5

	static func make(a: Vector2, b: Vector2, wavy := false) -> BreakLine:
		var l := BreakLine.new()
		l.kind = Kind.BREAK_LINE
		l.p1 = a
		l.p2 = b
		l.style = Style.WAVY if wavy else Style.STRAIGHT
		return l

	func kind_name() -> String:
		return "波浪线" if style == Style.WAVY else "折断线"

	func _build_curves() -> Array[GeoCurve]:
		var d := p2 - p1
		var total := d.length()
		if total <= Tol.MIN_LEN:
			return []
		var u := d / total
		var n := Vector2(-u.y, u.x)
		var amp := mm(amplitude_mm)
		var pts := PackedVector2Array()
		if style == Style.STRAIGHT:
			# 直线折断：中段画成 Z 字形（GB 规定的直线折断画法）
			var kink := minf(mm(2.0), total * 0.15)
			var mid := p1 + u * (total * 0.5)
			var a := p1 + u * (total * 0.5 - kink)
			var b := p1 + u * (total * 0.5 + kink)
			pts.append(p1)
			pts.append(a)
			pts.append(a + n * amp * 2.0)
			pts.append(b + n * amp * 2.0)
			pts.append(b)
			pts.append(p2)
			var _unused := mid
		else:
			# 波浪线：沿轴向的正弦波，幅度约 1.5mm
			var waves := maxf(2.0, total / mm(6.0))
			var steps := int(maxf(waves * 12.0, 24.0))
			for i in range(steps + 1):
				var t := float(i) / float(steps)
				var s := sin(t * TAU * waves)
				# 两端收拢，避免波浪线端点偏离实际位置
				var taper := sin(clampf(t, 0.0, 1.0) * PI)
				pts.append(p1 + u * (total * t) + n * (amp * s * taper))
		return [GeoPoly.make(pts, PackedFloat64Array(), false)]

	func get_grips() -> PackedVector2Array:
		return PackedVector2Array([p1, p2])

	func move_grip(i: int, p: Vector2) -> void:
		if i == 0:
			p1 = p
		elif i == 1:
			p2 = p
		invalidate_bbox()

	func transform_by(xf: Transform2D) -> void:
		p1 = xf * p1
		p2 = xf * p2
		invalidate_bbox()

	func clone() -> CadEntity:
		var c := BreakLine.make(p1, p2, style == Style.WAVY)
		c.amplitude_mm = amplitude_mm
		_copy_base_to(c)
		return c

	func to_dict() -> Dictionary:
		var d := super.to_dict()
		d["kind"] = Kind.BREAK_LINE
		_put_v2(d, "p1", p1)
		_put_v2(d, "p2", p2)
		d["style"] = style
		d["amplitude_mm"] = snappedf(amplitude_mm, 0.001)
		return d


# ===========================================================================
# 轴线号
# ===========================================================================

class AxisBubble extends Base:
	var position: Vector2 = Vector2.ZERO
	## 轴线编号：横向用阿拉伯数字，纵向用大写拉丁字母（不采用 I、O、Z）
	var label: String = "1"

	static func make(pos: Vector2, text: String) -> AxisBubble:
		var b := AxisBubble.new()
		b.kind = Kind.AXIS_BUBBLE
		b.position = pos
		b.label = text
		return b

	func kind_name() -> String:
		return "轴线号"

	func radius() -> float:
		# GB：细实线圆，直径 8~10mm，此处取 10mm
		return mm(5.0)

	func _build_curves() -> Array[GeoCurve]:
		return [GeoArc.make_circle(position, radius())]

	func get_annotation_texts() -> Array:
		return [{
			"text": label,
			"position": position,
			"rotation": 0.0,
			"height": mm(3.5),
			"style": "图名_7",
			"h_align": EntText.HAlign.CENTER,
			"v_align": EntText.VAlign.MIDDLE,
		}]

	func get_grips() -> PackedVector2Array:
		return PackedVector2Array([position])

	func move_grip(_i: int, p: Vector2) -> void:
		position = p
		invalidate_bbox()

	func transform_by(xf: Transform2D) -> void:
		position = xf * position
		invalidate_bbox()

	func clone() -> CadEntity:
		var c := AxisBubble.make(position, label)
		_copy_base_to(c)
		return c

	func to_dict() -> Dictionary:
		var d := super.to_dict()
		d["kind"] = Kind.AXIS_BUBBLE
		_put_v2(d, "position", position)
		d["label"] = label
		return d


# ===========================================================================
# 反序列化分发
# ===========================================================================

## 按 kind 重建符号图元
static func from_dict(d: Dictionary) -> CadEntity:
	var k := int(d.get("kind", -1))
	match k:
		Kind.ELEVATION:
			var e := Elevation.new()
			e.kind = k
			e.read_base_fields(d)
			e.position = CadEntity._v2(d, "position")
			e.elevation = float(d.get("elevation", 0.0))
			e.flip = bool(d.get("flip", false))
			return e
		Kind.INDEX, Kind.DETAIL:
			var m := IndexMark.new()
			m.kind = k
			m.read_base_fields(d)
			m.position = CadEntity._v2(d, "position")
			m.top_text = String(d.get("top_text", ""))
			m.bottom_text = String(d.get("bottom_text", ""))
			m.is_detail = bool(d.get("is_detail", k == Kind.DETAIL))
			m.has_leader = bool(d.get("has_leader", false))
			m.leader_to = CadEntity._v2(d, "leader_to")
			return m
		Kind.SECTION:
			var s := SectionMark.new()
			s.kind = k
			s.read_base_fields(d)
			s.p1 = CadEntity._v2(d, "p1")
			s.p2 = CadEntity._v2(d, "p2")
			s.side = int(d.get("side", 1))
			s.number = String(d.get("number", "1"))
			return s
		Kind.LEADER:
			var l := Leader.new()
			l.kind = k
			l.read_base_fields(d)
			l.points = CadEntity._arr_to_pts(d.get("points", []))
			l.text = String(d.get("text", ""))
			l.arrow = bool(d.get("arrow", true))
			return l
		Kind.BREAK_LINE:
			var b := BreakLine.new()
			b.kind = k
			b.read_base_fields(d)
			b.p1 = CadEntity._v2(d, "p1")
			b.p2 = CadEntity._v2(d, "p2")
			b.style = int(d.get("style", BreakLine.Style.STRAIGHT))
			b.amplitude_mm = float(d.get("amplitude_mm", 1.5))
			return b
		Kind.AXIS_BUBBLE:
			var a := AxisBubble.new()
			a.kind = k
			a.read_base_fields(d)
			a.position = CadEntity._v2(d, "position")
			a.label = String(d.get("label", ""))
			return a
	push_warning("未知的符号类型 kind=%d" % k)
	return null
