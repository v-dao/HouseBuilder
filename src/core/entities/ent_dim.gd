class_name EntDim
extends CadEntity
## 尺寸标注。对应 DXF 的 DIMENSION（各类型的组码差异由 io/dxf_writer 处理）。
##
## 几何按 GB/T 50001—2017 第 11 章生成：
##   · 尺寸界线用细实线，自图形轮廓线引出，并超出尺寸线 2~3mm
##   · 尺寸起止符号用中粗斜短线，与尺寸线成 45°，长 2~3mm
##   · 尺寸线用细实线，与被标注长度平行，距图样轮廓线不宜小于 10mm
##   · 尺寸数字字高 2.5 或 3.5mm，注写在尺寸线上方中部
##   · 竖直方向的尺寸数字，字头应朝左（即整条文字旋转 90°）
##
## 标注元素（界线超出量、起止符号长度、文字间隙）都按出图比例放大，
## 这样打印到图纸上的尺寸才是恒定的 —— 这是标注与普通图元最大的不同。

enum DimType {
	LINEAR,     ## 线性（水平或竖直，按尺寸线位置自动判定）
	ALIGNED,    ## 对齐（沿两点连线方向量取真实距离）
	RADIUS,     ## 半径
	DIAMETER,   ## 直径
	ANGULAR,    ## 角度
}

var dim_type: int = DimType.LINEAR
## 标注样式名。几何与文字参数都从文档的该样式实时解析。
var dim_style_name: String = ""
## 文字样式名（尺寸数字用）
var text_style_name: String = "标注_2.5"

## 尺寸界线的两个原点（被标注的两个点）
var p1: Vector2 = Vector2.ZERO
var p2: Vector2 = Vector2.ZERO
## 尺寸线通过的点，决定尺寸线位置与（线性标注的）测量方向
var line_pos: Vector2 = Vector2.ZERO
## 半径/直径/角度的圆心或顶点
var center: Vector2 = Vector2.ZERO
## 半径/直径标注时点取圆弧的位置；角度标注时用于确定圆弧半径
var arc_pos: Vector2 = Vector2.ZERO
## 文字覆盖值。为空时使用实测值。
var text_override: String = ""


static func make_linear(a: Vector2, b: Vector2, lp: Vector2) -> EntDim:
	var d := EntDim.new()
	d.type = CadEntity.Type.DIMENSION
	d.dim_type = DimType.LINEAR
	d.p1 = a
	d.p2 = b
	d.line_pos = lp
	return d


static func make_aligned(a: Vector2, b: Vector2, lp: Vector2) -> EntDim:
	var d := EntDim.new()
	d.type = CadEntity.Type.DIMENSION
	d.dim_type = DimType.ALIGNED
	d.p1 = a
	d.p2 = b
	d.line_pos = lp
	return d


static func make_radius(c: Vector2, on_arc: Vector2, label_pos: Vector2) -> EntDim:
	var d := EntDim.new()
	d.type = CadEntity.Type.DIMENSION
	d.dim_type = DimType.RADIUS
	d.center = c
	d.arc_pos = on_arc
	d.line_pos = label_pos
	return d


static func make_diameter(c: Vector2, on_arc: Vector2, label_pos: Vector2) -> EntDim:
	var d := EntDim.new()
	d.type = CadEntity.Type.DIMENSION
	d.dim_type = DimType.DIAMETER
	d.center = c
	d.arc_pos = on_arc
	d.line_pos = label_pos
	return d


static func make_angular(vertex: Vector2, a: Vector2, b: Vector2, arc_r_pos: Vector2) -> EntDim:
	var d := EntDim.new()
	d.type = CadEntity.Type.DIMENSION
	d.dim_type = DimType.ANGULAR
	d.center = vertex
	d.p1 = a
	d.p2 = b
	d.arc_pos = arc_r_pos
	return d


func type_name() -> String:
	match dim_type:
		DimType.LINEAR:
			return "线性标注"
		DimType.ALIGNED:
			return "对齐标注"
		DimType.RADIUS:
			return "半径标注"
		DimType.DIAMETER:
			return "直径标注"
		DimType.ANGULAR:
			return "角度标注"
	return "标注"


## 取标注样式。优先从所属文档实时解析，脱离文档时退回一份默认样式。
func style() -> CadDimStyle:
	var doc := get_document()
	if doc != null and dim_style_name != "":
		var s := doc.get_dim_style(dim_style_name)
		if s != null:
			return s
	var fallback := CadDimStyle.make("默认")
	fallback.overall_scale = 100.0
	return fallback


## 实测值（模型单位，即 mm）
func measured_value() -> float:
	match dim_type:
		DimType.LINEAR:
			var axis := _linear_axis()
			if axis == 0:
				return absf(p2.x - p1.x)
			return absf(p2.y - p1.y)
		DimType.ALIGNED:
			return p1.distance_to(p2)
		DimType.RADIUS:
			return center.distance_to(arc_pos)
		DimType.DIAMETER:
			return center.distance_to(arc_pos) * 2.0
		DimType.ANGULAR:
			return rad_to_deg(_angular_sweep())
	return 0.0


func display_text() -> String:
	if text_override != "":
		return text_override
	var st := style()
	var v := measured_value()
	var body := ""
	if st.text_round > 0:
		body = ("%." + str(st.text_round) + "f") % v
	else:
		body = "%.0f" % v
	match dim_type:
		DimType.RADIUS:
			return st.radius_prefix + body
		DimType.DIAMETER:
			return st.diameter_prefix + body
		DimType.ANGULAR:
			return body + "°"
	return st.prefix + body + st.suffix


## 线性标注的测量轴：0 = 水平（量 Δx），1 = 竖直（量 Δy）。
##
## 判据是尺寸线相对 **p1p2 中点** 的偏移方向，不是相对 p1。
## 举个反例说明为什么不能拿 p1 比：p1=(0,0)、p2=(3600,0)、尺寸线在中点正下方
## line_pos=(1800,-500)，相对 p1 的偏移是 Δx=1800 > Δy=500，
## 按 p1 判会误判成竖直标注，而实际这是最典型的水平标注。
func _linear_axis() -> int:
	var mid := (p1 + p2) * 0.5
	var d := line_pos - mid
	return 0 if absf(d.y) >= absf(d.x) else 1


func _angular_sweep() -> float:
	var a1 := (p1 - center).angle()
	var a2 := (p2 - center).angle()
	var sw := Tol.norm_angle(a2 - a1)
	if sw > PI:
		sw = TAU - sw
	return sw


# ---------------------------------------------------------------------------
# 几何生成
# ---------------------------------------------------------------------------

func get_curves() -> Array[GeoCurve]:
	match dim_type:
		DimType.LINEAR, DimType.ALIGNED:
			return _linear_curves()
		DimType.RADIUS, DimType.DIAMETER:
			return _radial_curves()
		DimType.ANGULAR:
			return _angular_curves()
	return []


## 线性 / 对齐标注：尺寸界线 + 尺寸线 + 两端 45° 斜短线
func _linear_curves() -> Array[GeoCurve]:
	var out: Array[GeoCurve] = []
	var st := style()
	var d1: Vector2
	var d2: Vector2
	if dim_type == DimType.ALIGNED:
		# 尺寸线平行于两点连线，偏移量由 line_pos 在法向的投影决定
		var dir := (p2 - p1)
		if dir.length() <= Tol.MIN_LEN:
			return out
		dir = dir.normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var off := (line_pos - p1).dot(nrm)
		d1 = p1 + nrm * off
		d2 = p2 + nrm * off
	else:
		if _linear_axis() == 0:
			d1 = Vector2(p1.x, line_pos.y)
			d2 = Vector2(p2.x, line_pos.y)
		else:
			d1 = Vector2(line_pos.x, p1.y)
			d2 = Vector2(line_pos.x, p2.y)

	var dir_d := d2 - d1
	if dir_d.length() <= Tol.MIN_LEN:
		return out
	var du := dir_d.normalized()

	# 尺寸界线：自原点引到尺寸线，再超出一段 ext_line_extension。
	# 超出方向必须由「原点 -> 尺寸线」的实际方向决定，
	# 不能想当然地沿尺寸线方向——竖直标注的界线是水平的。
	var ext_over := st.scaled(st.ext_line_extension)
	out.append(GeoSeg.make(p1, _ext_end(p1, d1, ext_over)))
	out.append(GeoSeg.make(p2, _ext_end(p2, d2, ext_over)))

	# 尺寸线
	out.append(GeoSeg.make(d1, d2))

	# 两端 45° 斜短线起止符号
	var tick := st.scaled(st.terminator_size)
	if st.terminator == CadDimStyle.Terminator.OBLIQUE:
		out.append(GeoSeg.make(d1 - _tick_dir(du) * tick * 0.5, d1 + _tick_dir(du) * tick * 0.5))
		out.append(GeoSeg.make(d2 - _tick_dir(du) * tick * 0.5, d2 + _tick_dir(du) * tick * 0.5))
	elif st.terminator == CadDimStyle.Terminator.ARROW:
		# 箭头指向各自那一侧的尺寸界线
		for c in _arrow(d1, -du, st.scaled(st.arrow_size)):
			out.append(c)
		for c in _arrow(d2, du, st.scaled(st.arrow_size)):
			out.append(c)
	return out


## 尺寸界线的外端：从原点穿过尺寸线，再超出一段
func _ext_end(origin: Vector2, at_dim_line: Vector2, overshoot: float) -> Vector2:
	var v := at_dim_line - origin
	var l := v.length()
	if l <= Tol.MIN_LEN:
		return at_dim_line
	return at_dim_line + (v / l) * overshoot


## 45° 斜短线方向：把尺寸线方向逆时针转 45°
func _tick_dir(du: Vector2) -> Vector2:
	return Vector2(du.x * cos(PI / 4.0) - du.y * sin(PI / 4.0),
		du.x * sin(PI / 4.0) + du.y * cos(PI / 4.0))


## 半径 / 直径：引线 + 起止符号
func _radial_curves() -> Array[GeoCurve]:
	var out: Array[GeoCurve] = []
	var st := style()
	var v := arc_pos - center
	var r := v.length()
	if r <= Tol.MIN_LEN:
		return out
	var dir := v / r
	var al := st.scaled(st.arrow_size)
	if dim_type == DimType.RADIUS:
		# 自圆心引出到圆弧，箭头尖落在圆弧上、指向圆弧外侧
		out.append(GeoSeg.make(center, arc_pos))
		for c in _arrow(arc_pos, dir, al):
			out.append(c)
	else:
		# 直径：贯穿圆心，两端箭头都指向各自那一侧的圆弧
		var a2 := center - dir * r
		out.append(GeoSeg.make(a2, arc_pos))
		for c in _arrow(arc_pos, dir, al):
			out.append(c)
		for c in _arrow(a2, -dir, al):
			out.append(c)
	return out


## 生成一个箭头（等腰三角形轮廓）。
## tip 是箭尖位置，dir 是箭头**指向**，size 为箭头长度。
## GB 规定箭头长 3~4mm；这里画三角形轮廓而非实心，
## 因为实心需要填充能力，而轮廓在图纸尺度下视觉等价。
func _arrow(tip: Vector2, dir: Vector2, size: float) -> Array[GeoCurve]:
	var out: Array[GeoCurve] = []
	if dir.length() <= Tol.MIN_LEN or size <= Tol.MIN_LEN:
		return out
	var u := dir.normalized()
	var back := tip - u * size
	var p := _perp(u) * size * 0.32
	out.append(GeoSeg.make(tip, back + p))
	out.append(GeoSeg.make(tip, back - p))
	out.append(GeoSeg.make(back + p, back - p))
	return out

func _perp(v: Vector2) -> Vector2:
	return Vector2(-v.y, v.x)


## 角度标注：以顶点为圆心的圆弧 + 两端箭头
func _angular_curves() -> Array[GeoCurve]:
	var out: Array[GeoCurve] = []
	var st := style()
	var r := center.distance_to(arc_pos)
	if r <= Tol.MIN_LEN:
		r = maxf(center.distance_to(p1), center.distance_to(p2)) * 0.6
	var a1 := (p1 - center).angle()
	var a2 := (p2 - center).angle()
	# 取小于 180° 的那一侧
	var ccw := Tol.norm_angle(a2 - a1) <= PI
	out.append(GeoArc.make(center, r, a1, a2, ccw))
	var al := st.scaled(st.arrow_size)
	var p_start := center + Vector2(cos(a1), sin(a1)) * r
	var p_end := center + Vector2(cos(a2), sin(a2)) * r
	# t_start/t_end 是沿圆弧的行进方向；角度标注的两端箭头都朝外，
	# 即起点处的箭头指向 -t_start、终点处指向 +t_end。
	var t_start := Vector2(-sin(a1), cos(a1)) * (1.0 if ccw else -1.0)
	var t_end := Vector2(-sin(a2), cos(a2)) * (1.0 if ccw else -1.0)
	for c in _arrow(p_start, -t_start, al):
		out.append(c)
	for c in _arrow(p_end, t_end, al):
		out.append(c)
	return out


# ---------------------------------------------------------------------------
# 尺寸数字的位置与朝向
# ---------------------------------------------------------------------------

## 尺寸线方向角，归一化到 [0, 180°)。
## GB 要求竖直尺寸的数字字头朝左，把角度归一化到 [0,180) 正好满足：
## 尺寸线朝下时会被翻成朝上，文字随之为正向可读且字头朝左。
func _text_angle() -> float:
	var du := _dim_line_dir()
	var a := fposmod(du.angle(), PI)
	if a < 0.0:
		a += PI
	return a


func _dim_line_dir() -> Vector2:
	match dim_type:
		DimType.LINEAR:
			if _linear_axis() == 0:
				return Vector2(1, 0)
			return Vector2(0, 1)
		DimType.ALIGNED:
			var d := p2 - p1
			return d.normalized() if d.length() > Tol.MIN_LEN else Vector2.RIGHT
		DimType.RADIUS, DimType.DIAMETER:
			var v := arc_pos - center
			return v.normalized() if v.length() > Tol.MIN_LEN else Vector2.RIGHT
		DimType.ANGULAR:
			return Vector2.RIGHT
	return Vector2.RIGHT


## 尺寸数字的插入点（基线中心）
func text_position() -> Vector2:
	var st := style()
	match dim_type:
		DimType.LINEAR, DimType.ALIGNED:
			var d1: Vector2
			var d2: Vector2
			if dim_type == DimType.ALIGNED:
				var dir := (p2 - p1)
				if dir.length() <= Tol.MIN_LEN:
					return p1
				dir = dir.normalized()
				var nrm := Vector2(-dir.y, dir.x)
				var off := (line_pos - p1).dot(nrm)
				d1 = p1 + nrm * off
				d2 = p2 + nrm * off
			elif _linear_axis() == 0:
				d1 = Vector2(p1.x, line_pos.y)
				d2 = Vector2(p2.x, line_pos.y)
			else:
				d1 = Vector2(line_pos.x, p1.y)
				d2 = Vector2(line_pos.x, p2.y)
			var mid := (d1 + d2) * 0.5
			# 沿尺寸线的法向（逆时针 90°）抬起一个间隙，文字即在尺寸线上方
			var du := (d2 - d1)
			du = du.normalized() if du.length() > Tol.MIN_LEN else Vector2.RIGHT
			var nrm2 := _perp(du)
			return mid + nrm2 * st.scaled(st.text_gap)
		DimType.RADIUS, DimType.DIAMETER:
			# 文字放在圆弧外侧，沿引线方向再向外偏一段
			var v := arc_pos - center
			var l := v.length()
			if l <= Tol.MIN_LEN:
				return arc_pos
			return arc_pos + (v / l) * st.scaled(st.text_gap + st.text_height)
		DimType.ANGULAR:
			var a1 := (p1 - center).angle()
			var a2 := (p2 - center).angle()
			var ccw := Tol.norm_angle(a2 - a1) <= PI
			var sweep := Tol.norm_angle(a2 - a1) if ccw else -Tol.norm_angle(a1 - a2)
			var am := a1 + sweep * 0.5
			var r := center.distance_to(arc_pos)
			if r <= Tol.MIN_LEN:
				r = 100.0
			return center + Vector2(cos(am), sin(am)) * (r + st.scaled(st.text_gap + st.text_height * 0.5))
	return p1


## 把尺寸数字交给统一文字渲染通道
func get_annotation_texts() -> Array:
	var txt := display_text()
	if txt == "":
		return []
	var st := style()
	return [{
		"text": txt,
		"position": text_position(),
		"rotation": _text_angle(),
		# 关键：样式里的 text_height 是"图纸上的毫米"（GB 规定 2.5mm），
		# 模型空间是 1:1 真实尺寸，故必须乘出图比例。
		# 1:100 时模型里应为 250mm，否则尺寸数字会小到看不见。
		"height": st.scaled(st.text_height),
		"style": text_style_name,
		"h_align": EntText.HAlign.CENTER,
		# BOTTOM 使文字整体位于插入点朝向尺寸线法向的一侧，
		# 水平标注表现为"在线上方"，竖直标注表现为"在线左侧"，与 GB 一致
		"v_align": EntText.VAlign.BOTTOM,
	}]


func get_bbox() -> Rect2:
	var curves := get_curves()
	var bb: Rect2
	if curves.is_empty():
		bb = Rect2(text_position(), Vector2.ZERO)
	else:
		bb = curves[0].bbox()
		for i in range(1, curves.size()):
			bb = bb.merge(curves[i].bbox())
	# 并入文字范围，否则标注的可拾取区域会漏掉数字
	var st := style()
	var tp := text_position()
	var h := st.scaled(st.text_height)
	var w := h * 0.7 * maxf(float(display_text().length()), 1.0)
	bb = bb.merge(Rect2(tp - Vector2(w, h) * 0.5, Vector2(w, h)))
	return bb


func get_grips() -> PackedVector2Array:
	match dim_type:
		DimType.LINEAR, DimType.ALIGNED:
			return PackedVector2Array([p1, p2, line_pos])
		DimType.RADIUS, DimType.DIAMETER:
			return PackedVector2Array([center, arc_pos])
		DimType.ANGULAR:
			return PackedVector2Array([center, p1, p2, arc_pos])
	return PackedVector2Array()


func move_grip(index: int, pos: Vector2) -> void:
	match dim_type:
		DimType.LINEAR, DimType.ALIGNED:
			match index:
				0:
					p1 = pos
				1:
					p2 = pos
				2:
					line_pos = pos
		DimType.RADIUS, DimType.DIAMETER:
			match index:
				0:
					center = pos
				1:
					arc_pos = pos
		DimType.ANGULAR:
			match index:
				0:
					center = pos
				1:
					p1 = pos
				2:
					p2 = pos
				3:
					arc_pos = pos
	invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	p1 = xf * p1
	p2 = xf * p2
	line_pos = xf * line_pos
	center = xf * center
	arc_pos = xf * arc_pos
	invalidate_bbox()


func clone() -> CadEntity:
	var d := EntDim.new()
	d.type = CadEntity.Type.DIMENSION
	d.dim_type = dim_type
	d.dim_style_name = dim_style_name
	d.text_style_name = text_style_name
	d.p1 = p1
	d.p2 = p2
	d.line_pos = line_pos
	d.center = center
	d.arc_pos = arc_pos
	d.text_override = text_override
	_copy_base_to(d)
	return d


func explode() -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	for c in get_curves():
		if c.kind() == GeoCurve.Kind.SEG:
			var s := c as GeoSeg
			var e := EntLine.make(s.a, s.b)
			_copy_base_to(e)
			out.append(e)
	# 尺寸数字独立成文字图元
	var txt := display_text()
	if txt != "":
		var t := EntText.make(text_position(), txt, style().scaled(style().text_height), _text_angle())
		t.text_style = text_style_name
		t.h_align = EntText.HAlign.CENTER
		t.v_align = EntText.VAlign.BOTTOM
		_copy_base_to(t)
		out.append(t)
	return out


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["dim_type"] = dim_type
	d["dim_style_name"] = dim_style_name
	d["text_style_name"] = text_style_name
	_put_v2(d, "p1", p1)
	_put_v2(d, "p2", p2)
	_put_v2(d, "line_pos", line_pos)
	_put_v2(d, "center", center)
	_put_v2(d, "arc_pos", arc_pos)
	if text_override != "":
		d["text_override"] = text_override
	return d


static func from_dict(d: Dictionary) -> EntDim:
	var e := EntDim.new()
	e.type = CadEntity.Type.DIMENSION
	e.read_base_fields(d)
	e.dim_type = int(d.get("dim_type", DimType.LINEAR))
	e.dim_style_name = String(d.get("dim_style_name", ""))
	e.text_style_name = String(d.get("text_style_name", "标注_2.5"))
	e.p1 = _v2(d, "p1")
	e.p2 = _v2(d, "p2")
	e.line_pos = _v2(d, "line_pos")
	e.center = _v2(d, "center")
	e.arc_pos = _v2(d, "arc_pos")
	e.text_override = String(d.get("text_override", ""))
	return e
