class_name AxisGrid
extends RefCounted
## 参数化轴网。
##
## 轴网是建筑平面图的骨架：定位轴线用细单点长画线，端部画轴线号圆圈。
## GB/T 50001 规定：
##   · 定位轴线用细单点长画线绘制
##   · 轴线编号注写在轴线端部的圆内，圆用细实线，直径 8~10mm
##   · 横向编号用阿拉伯数字，从左至右；纵向编号用大写拉丁字母，从下至上
##   · **纵向编号不采用 I、O、Z**，以免与 1、0、2 混淆
##
## 轴线号与圆由 EntSymbols.AxisBubble 生成，因此符号改动会同步反映到轴网。


## 纵向编号序列：A B C D E F G H J K L M N P Q R S T U V W X Y
## 跳过 I、O、Z（GB/T 50001 第 9 章）
const SKIP_LETTERS := ["I", "O", "Z"]


## 生成 n 个纵向编号
static func axis_letters(n: int) -> Array[String]:
	var out: Array[String] = []
	var i := 0
	while out.size() < n and i < 26:
		var ch := String.chr(65 + i)
		if not SKIP_LETTERS.has(ch):
			out.append(ch)
		i += 1
	return out


## 生成 n 个横向编号
static func axis_numbers(n: int) -> Array[String]:
	var out: Array[String] = []
	for i in range(n):
		out.append(str(i + 1))
	return out


## 解析轴距输入。支持混合写法：
##   "3600 4200 3600"   直接给出各段
##   "3*3600 4200"      3 段 3600 再加一段 4200
## 返回各段长度，输入非法时返回空数组。
static func parse_spans(text: String) -> Array[float]:
	var out: Array[float] = []
	var tokens := text.strip_edges().split(" ", false)
	for t in tokens:
		var tok := String(t).strip_edges()
		if tok == "":
			continue
		if tok.contains("*"):
			var parts := tok.split("*")
			if parts.size() != 2:
				return []
			var cnt := int(parts[0].to_float())
			var span := parts[1].to_float()
			if cnt <= 0 or span <= 0.0:
				return []
			for i in range(cnt):
				out.append(span)
		else:
			var v := tok.to_float()
			if v <= 0.0:
				return []
			out.append(v)
	return out


## 由各段长度累加出各轴线位置（含起点 0）
static func positions_from_spans(spans: Array) -> Array[float]:
	var out: Array[float] = [0.0]
	var acc := 0.0
	for s in spans:
		acc += s
		out.append(acc)
	return out


## 生成轴网。
##   xs / ys      各轴线的相对位置（由 positions_from_spans 得到，或直接给绝对值）
##   origin       轴网起点（左下角）在模型空间的坐标
##   margin       轴线超出最外轴线的长度（mm）
##   bubble_gap   轴线号圆心距最外轴线的距离（mm）
##   with_dims    是否同时生成三道尺寸线（门窗定位 / 轴线 / 总尺寸）
## 返回建立的图层名。
static func build(doc: CadDocument, xs: Array, ys: Array,
		origin: Vector2, margin := 900.0, bubble_gap := 1200.0,
		with_dims := true, dim_layer := "尺寸标注") -> void:
	if xs.size() < 2 or ys.size() < 2:
		return
	var ax := _ensure_layer(doc, "轴线", 0.25, "CENTER")
	var y_min := origin.y + float(ys[0]) - margin
	var y_max := origin.y + float(ys[ys.size() - 1]) + margin
	var x_min := origin.x + float(xs[0]) - margin
	var x_max := origin.x + float(xs[xs.size() - 1]) + margin

	# 横向编号用数字（左->右）
	var nums := axis_numbers(xs.size())
	for i in range(xs.size()):
		var x := origin.x + float(xs[i])
		_line(doc, ax, Vector2(x, y_min), Vector2(x, y_max))
		# 下端与上端各一个轴线号
		_bubble(doc, ax, Vector2(x, y_min - bubble_gap), nums[i])
		_bubble(doc, ax, Vector2(x, y_max + bubble_gap), nums[i])

	# 纵向编号用字母（下->上），跳过 I O Z
	var letters := axis_letters(ys.size())
	for j in range(ys.size()):
		var y := origin.y + float(ys[j])
		_line(doc, ax, Vector2(x_min, y), Vector2(x_max, y))
		_bubble(doc, ax, Vector2(x_min - bubble_gap, y), letters[j])
		_bubble(doc, ax, Vector2(x_max + bubble_gap, y), letters[j])

	if with_dims:
		build_dimensions(doc, xs, ys, origin, margin, dim_layer)


## 三道尺寸线（GB/T 50001：总尺寸 / 轴线尺寸 / 门窗定位尺寸）
static func build_dimensions(doc: CadDocument, xs: Array, ys: Array,
		origin: Vector2, margin: float, dim_layer: String) -> void:
	var st := doc.get_dim_style(doc.current_dim_style)
	var scale := st.overall_scale if st != null else 100.0
	var base := margin + 600.0
	var step := (st.baseline_spacing if st != null else 8.0) * scale
	var x_abs: Array[float] = []
	for x in xs:
		x_abs.append(origin.x + float(x))
	var y_abs: Array[float] = []
	for y in ys:
		y_abs.append(origin.y + float(y))
	var y0 := origin.y + float(ys[0])
	var x0 := origin.x + float(xs[0])
	# 三道：轴线尺寸、总尺寸（此处暂生成两道，门窗定位尺寸在插入门窗后由 DIMGRID 补）
	for k in range(2):
		var off := base + step * float(k)
		_dim_chain(doc, x_abs, y0 - off, true, dim_layer)
		_dim_chain(doc, y_abs, x0 - off, false, dim_layer)


static func _dim_chain(doc: CadDocument, positions: Array, fixed: float,
		horizontal: bool, dim_layer: String) -> void:
	for i in range(positions.size() - 1):
		var a: Vector2
		var b: Vector2
		var loc: Vector2
		if horizontal:
			a = Vector2(positions[i], fixed)
			b = Vector2(positions[i + 1], fixed)
			loc = Vector2((positions[i] + positions[i + 1]) * 0.5, fixed - 1.0)
		else:
			a = Vector2(fixed, positions[i])
			b = Vector2(fixed, positions[i + 1])
			# 竖直标注：尺寸线放在两点中点左侧
			loc = Vector2(fixed - 1.0, (positions[i] + positions[i + 1]) * 0.5)
		var d := EntDim.make_linear(a, b, loc)
		d.dim_style_name = doc.current_dim_style
		d.text_style_name = "标注_2.5"
		d.layer = dim_layer
		d.aci = 256
		doc.add_entity(d, false)


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

static func _ensure_layer(doc: CadDocument, name: String, lw: float, lt: String) -> String:
	var l := doc.ensure_layer(name)
	if l != null:
		if l.lineweight < 0.0:
			l.lineweight = lw
		if l.linetype == "CONTINUOUS" and lt != "CONTINUOUS":
			l.linetype = lt
	return name


static func _line(doc: CadDocument, layer: String, a: Vector2, b: Vector2) -> void:
	var e := EntLine.make(a, b)
	e.layer = layer
	e.aci = 256
	doc.add_entity(e, false)


static func _bubble(doc: CadDocument, layer: String, pos: Vector2, label: String) -> void:
	var b := EntSymbols.AxisBubble.make(pos, label)
	b.layer = layer
	b.aci = 256
	doc.add_entity(b, false)
