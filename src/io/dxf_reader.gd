class_name DxfReader
extends RefCounted
## DXF 读入。
##
## 定位：**能读回自己导出的图纸**，并能读入设计院给的常见 R12 / R2000 图纸的基本图元。
## 天正自定义实体（墙/门窗/标注）在纯 AutoCAD 下就是普通线，因此能被读成线段，
## 但会丢失"这是墙"这层语义 —— 这是格式本身的限制，不是实现问题。
##
## 容错策略：单个图元解析失败时跳过并记录，绝不让整张图读不进来。
## 外部图纸千奇百怪，宁可少读几个实体，也不能因为一个异常把用户拦在门外。

## 解析过程中的告警（跳过的实体、未支持的类型等）
var warnings: Array[String] = []
## 支持的实体类型统计
var stats: Dictionary = {}


## 从文件读入文档。返回 OK 或错误码。
func read_into(doc: CadDocument, path: String) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var raw := f.get_buffer(f.get_length())
	f.close()
	return read_bytes(doc, raw)


func read_bytes(doc: CadDocument, raw: PackedByteArray) -> Error:
	warnings.clear()
	stats.clear()
	var tags := _parse_tags(raw)
	if tags.size() < 2:
		return ERR_FILE_CORRUPT

	# 清空后重建
	doc.entities.clear()
	doc._by_handle.clear()
	doc._next_handle = 1
	doc.undo.clear()
	doc.layers.clear()
	doc.blocks.clear()
	doc.ensure_layer("0")

	_read_tables(doc, tags)
	_read_blocks(doc, tags)
	_read_entities(doc, tags)
	doc._bump()
	return OK


# ---------------------------------------------------------------------------
# 组码流解析
# ---------------------------------------------------------------------------

## 把文件解析成 [code:int, value:String] 的数组。
## 同时记录编码：R12 的中文是 GBK，R2007+ 是 UTF-8。
func _parse_tags(raw: PackedByteArray) -> Array:
	var text := ""
	var use_gbk := false
	# 先探测编码：UTF-8 解码后若出现大量替换字符，说明不是 UTF-8
	var as_utf8 := raw.get_string_from_utf8()
	var bad := 0
	for i in range(0, mini(as_utf8.length(), 20000)):
		if as_utf8.unicode_at(i) == 0xFFFD:
			bad += 1
	if bad > 20:
		use_gbk = true
	if use_gbk and Gbk.is_available():
		text = Gbk.decode(raw)
	else:
		# 去掉 UTF-8 BOM
		text = as_utf8
		if text.begins_with("\uFEFF"):
			text = text.substr(1)

	var lines := text.split("\n")
	var out: Array = []
	var i := 0
	while i + 1 < lines.size():
		var code_line := String(lines[i]).strip_edges()
		if code_line == "":
			i += 1
			continue
		if not code_line.is_valid_int():
			i += 1
			continue
		var code := code_line.to_int()
		# 值行可能带 \r（Windows 换行），去掉
		var value := String(lines[i + 1])
		if value.ends_with("\r"):
			value = value.substr(0, value.length() - 1)
		out.append([code, value])
		i += 2
	return out


# ---------------------------------------------------------------------------
# 表
# ---------------------------------------------------------------------------

func _read_tables(doc: CadDocument, tags: Array) -> void:
	var i := 0
	while i < tags.size():
		if int(tags[i][0]) == 0 and String(tags[i][1]) == "TABLE":
			var j := i + 1
			var kind := ""
			while j < tags.size() and int(tags[j][0]) != 0:
				if int(tags[j][0]) == 2:
					kind = String(tags[j][1])
				j += 1
			# 找到 ENDTAB 为止
			var end := j
			while end < tags.size():
				if int(tags[end][0]) == 0 and String(tags[end][1]) == "ENDTAB":
					break
				end += 1
			if kind == "LAYER":
				_read_layer_table(doc, tags, j, end)
			elif kind == "LTYPE":
				_read_linetype_table(doc, tags, j, end)
			elif kind == "STYLE":
				_read_style_table(doc, tags, j, end)
			i = end + 1
			continue
		i += 1


func _read_layer_table(doc: CadDocument, tags: Array, start: int, end: int) -> void:
	var i := start
	while i < end:
		if int(tags[i][0]) == 0 and String(tags[i][1]) == "LAYER":
			var l := CadLayer.new()
			var j := i + 1
			var flags := 0
			var color := 7
			while j < end and int(tags[j][0]) != 0:
				var c := int(tags[j][0])
				var v := String(tags[j][1])
				match c:
					2:
						l.name = v
					6:
						l.linetype = v
					62:
						color = v.to_int()
					370:
						# 线宽组码是 R2000 才引入的，R12 图层表里没有。
						# 读 R2000+ 的图纸时能拿到；读 R12 时保持默认值，
						# 由渲染与出图按图层颜色映射到线宽（国内用 .ctb 打印样式表）。
						var lw := v.to_int()
						l.lineweight = float(lw) / 100.0 if lw > 0 else CadLayer.LW_DEFAULT
					70:
						flags = v.to_int()
				j += 1
			if l.name == "":
				l.name = "0"
			l.aci = absi(color)
			l.color = _aci_color(l.aci)
			l.frozen = (flags & 1) != 0
			l.locked = (flags & 4) != 0
			l.visible = color >= 0
			doc.layers[l.name] = l
			i = j
			continue
		i += 1
	doc.ensure_layer("0")


func _read_linetype_table(doc: CadDocument, tags: Array, start: int, end: int) -> void:
	var i := start
	while i < end:
		if int(tags[i][0]) == 0 and String(tags[i][1]) == "LTYPE":
			var t := CadLinetype.new()
			var pat := PackedFloat64Array()
			var j := i + 1
			while j < end and int(tags[j][0]) != 0:
				var c := int(tags[j][0])
				var v := String(tags[j][1])
				if c == 2:
					t.name = v
				elif c == 3:
					t.description = v
				elif c == 49:
					pat.append(v.to_float())
				j += 1
			t.pattern = pat
			if t.name != "":
				doc.linetypes[t.name] = t
			i = j
			continue
		i += 1


func _read_style_table(doc: CadDocument, tags: Array, start: int, end: int) -> void:
	var i := start
	while i < end:
		if int(tags[i][0]) == 0 and String(tags[i][1]) == "STYLE":
			var s := CadTextStyle.new()
			var j := i + 1
			while j < end and int(tags[j][0]) != 0:
				var c := int(tags[j][0])
				var v := String(tags[j][1])
				match c:
					2:
						s.name = v
					40:
						s.height = v.to_float()
					41:
						s.width_factor = v.to_float() if v.to_float() > 0.0 else 1.0
					50:
						s.oblique_angle = deg_to_rad(v.to_float())
					3:
						# DXF 的字体文件名，尽量映射回系统字体
						var fn := v.to_lower()
						if fn.contains("fang") or fn.contains("fs"):
							s.system_font = "FangSong"
						elif fn.contains("hei"):
							s.system_font = "SimHei"
						elif fn.contains("kai"):
							s.system_font = "KaiTi"
				j += 1
			if s.name != "":
				doc.text_styles[s.name] = s
			i = j
			continue
		i += 1


# ---------------------------------------------------------------------------
# 块
# ---------------------------------------------------------------------------

func _read_blocks(doc: CadDocument, tags: Array) -> void:
	var i := 0
	while i < tags.size():
		if int(tags[i][0]) == 0 and String(tags[i][1]) == "BLOCK":
			var blk := CadBlock.new()
			var j := i + 1
			while j < tags.size() and int(tags[j][0]) != 0:
				var c := int(tags[j][0])
				var v := String(tags[j][1])
				match c:
					2:
						blk.name = v
					10:
						blk.base_point.x = v.to_float()
					20:
						blk.base_point.y = v.to_float()
				j += 1
			# 读块内实体直到 ENDBLK
			while j < tags.size():
				if int(tags[j][0]) == 0 and String(tags[j][1]) == "ENDBLK":
					break
				if int(tags[j][0]) == 0:
					var r := _read_entity(doc, tags, j)
					j = r[0]
					if r[1] != null:
						var e: CadEntity = r[1]
						e.owner_block = blk.name
						blk.entities.append(e)
					continue
				j += 1
			# 跳过 *Model_Space 这类匿名块
			if blk.name != "" and not blk.name.begins_with("*"):
				doc.blocks[blk.name] = blk
			i = j + 1
			continue
		i += 1


# ---------------------------------------------------------------------------
# 实体
# ---------------------------------------------------------------------------

func _read_entities(doc: CadDocument, tags: Array) -> void:
	var in_entities := false
	var i := 0
	while i < tags.size():
		var c := int(tags[i][0])
		var v := String(tags[i][1])
		if c == 0 and v == "SECTION":
			# 下一行应是组码 2
			if i + 1 < tags.size() and int(tags[i + 1][0]) == 2:
				in_entities = String(tags[i + 1][1]) == "ENTITIES"
				i += 2
				continue
		if c == 0 and v == "ENDSEC":
			in_entities = false
			i += 1
			continue
		if in_entities and c == 0:
			var r := _read_entity(doc, tags, i)
			i = r[0]
			if r[1] != null:
				doc.add_entity(r[1], false)
			continue
		i += 1


## 读一个实体。
## 返回值固定为两个元素：[下一个位置, 实体或 null]。
## 两个调用方（块内实体与实体段）都必须按这个约定取值 ——
## 之前一处按 r[1] 取位置、一处按 r[2] 取实体，就是这么写岔的。
func _read_entity(doc: CadDocument, tags: Array, start: int) -> Array:
	var type := String(tags[start][1])
	var d := {}
	var i := start + 1
	while i < tags.size() and int(tags[i][0]) != 0:
		var c := int(tags[i][0])
		var v := String(tags[i][1])
		# 同名组码可能重复（如多段线的 10/20），用数组存
		if d.has(c):
			var cur = d[c]
			if cur is Array:
				(cur as Array).append(v)
			else:
				d[c] = [cur, v]
		else:
			d[c] = v
		i += 1

	var e: CadEntity = null
	match type:
		"LINE":
			e = _mk_line(d)
		"CIRCLE":
			e = _mk_circle(d)
		"ARC":
			e = _mk_arc(d)
		"POINT":
			e = _mk_point(d)
		"TEXT":
			e = _mk_text(d)
		"MTEXT":
			e = _mk_mtext(d)
		"LWPOLYLINE":
			e = _mk_lwpolyline(d)
			# LWPOLYLINE 后面通常跟一个 0 组码，位置不变
		"POLYLINE":
			var r := _mk_polyline(doc, tags, start)
			e = r[0]
			i = r[1]
		"INSERT":
			e = _mk_insert(d)
		"ELLIPSE":
			e = _mk_ellipse(d)
		"SPLINE":
			e = _mk_spline(d)
		_:
			if type != "SEQEND" and type != "VERTEX" and type != "ENDBLK":
				_note("跳过不支持的实体类型：%s" % type)
	if e != null:
		e.layer = String(d.get(8, "0"))
		if not doc.layers.has(e.layer):
			doc.ensure_layer(e.layer)
		var aci := String(d.get(62, "256")).to_int()
		e.aci = aci if aci != 0 else 256
		if aci > 0 and aci <= 255:
			e.color = _aci_color(aci)
		stats[type] = int(stats.get(type, 0)) + 1
	return [i, e]


func _f(d: Dictionary, code: int, def := 0.0) -> float:
	if not d.has(code):
		return def
	var v = d[code]
	if v is Array:
		return float((v as Array)[0])
	return String(v).to_float()


func _s(d: Dictionary, code: int, def := "") -> String:
	if not d.has(code):
		return def
	var v = d[code]
	if v is Array:
		return String((v as Array)[0])
	return String(v)


## 取某组码的全部出现（多段线的 10/20 会重复）
func _all(d: Dictionary, code: int) -> Array:
	if not d.has(code):
		return []
	var v = d[code]
	return v if v is Array else [v]


func _mk_line(d: Dictionary) -> CadEntity:
	return EntLine.make(Vector2(_f(d, 10), _f(d, 20)), Vector2(_f(d, 11), _f(d, 21)))


func _mk_circle(d: Dictionary) -> CadEntity:
	return EntCircle.make(Vector2(_f(d, 10), _f(d, 20)), _f(d, 40, 1.0))


func _mk_arc(d: Dictionary) -> CadEntity:
	return EntArc.make(Vector2(_f(d, 10), _f(d, 20)), _f(d, 40, 1.0),
		deg_to_rad(_f(d, 50)), deg_to_rad(_f(d, 51)))


func _mk_point(d: Dictionary) -> CadEntity:
	return EntPoint.make(Vector2(_f(d, 10), _f(d, 20)))


func _mk_text(d: Dictionary) -> CadEntity:
	var t := EntText.make(Vector2(_f(d, 10), _f(d, 20)), _s(d, 1), maxf(_f(d, 40, 3.5), 0.1),
		deg_to_rad(_f(d, 50)))
	var st := _s(d, 7)
	if st != "":
		t.text_style = st
	# 72 是水平对正、73 是垂直对正；非左对齐时插入点在 11/21
	var h := String(d.get(72, "0")).to_int()
	var v := String(d.get(73, "0")).to_int()
	match h:
		1, 4:
			t.h_align = EntText.HAlign.CENTER
		2:
			t.h_align = EntText.HAlign.RIGHT
	match v:
		1:
			t.v_align = EntText.VAlign.BOTTOM
		2:
			t.v_align = EntText.VAlign.MIDDLE
		3:
			t.v_align = EntText.VAlign.TOP
	if (h != 0 or v != 0) and d.has(11):
		t.position = Vector2(_f(d, 11), _f(d, 21))
	return t


func _mk_mtext(d: Dictionary) -> CadEntity:
	var txt := _s(d, 1)
	# MTEXT 的格式码：\P 是换行，\{ \} 是分组，\L 等是格式；这里只做最必要的还原
	txt = txt.replace("\\P", "\n").replace("\\p", "\n")
	# EntMText.make 只接受 (位置, 内容, 字高) 三个参数，旋转角要单独设
	var e := EntMText.make(Vector2(_f(d, 10), _f(d, 20)), txt, maxf(_f(d, 40, 3.5), 0.1))
	e.rotation = deg_to_rad(_f(d, 50))
	var w := _f(d, 41, 0.0)
	if w > 0.0:
		e.width = w
	var att := String(d.get(71, "1")).to_int()
	# DXF 的 1..9 对应左上、中上、右上、左中、正中、右中、左下、中下、右下
	var att_map := [EntMText.Attach.TOP_LEFT, EntMText.Attach.TOP_CENTER, EntMText.Attach.TOP_RIGHT,
		EntMText.Attach.MIDDLE_LEFT, EntMText.Attach.MIDDLE_CENTER, EntMText.Attach.MIDDLE_RIGHT,
		EntMText.Attach.BOTTOM_LEFT, EntMText.Attach.BOTTOM_CENTER, EntMText.Attach.BOTTOM_RIGHT]
	e.attach = att_map[clampi(att - 1, 0, 8)]
	return e


func _mk_lwpolyline(d: Dictionary) -> CadEntity:
	var xs := _all(d, 10)
	var ys := _all(d, 20)
	var bs := _all(d, 42)
	var pts := PackedVector2Array()
	var bls := PackedFloat64Array()
	var n := mini(xs.size(), ys.size())
	for i in range(n):
		pts.append(Vector2(String(xs[i]).to_float(), String(ys[i]).to_float()))
		bls.append(String(bs[i]).to_float() if i < bs.size() else 0.0)
	if pts.size() < 2:
		return null
	var flags := String(d.get(70, "0")).to_int()
	return EntPolyline.make(pts, bls, (flags & 1) != 0)


## POLYLINE 由 POLYLINE + 若干 VERTEX + SEQEND 三段组成，需要连续读
func _mk_polyline(doc: CadDocument, tags: Array, start: int) -> Array:
	var flags := 0
	var i := start + 1
	while i < tags.size() and int(tags[i][0]) != 0:
		if int(tags[i][0]) == 70:
			flags = String(tags[i][1]).to_int()
		i += 1
	var pts := PackedVector2Array()
	var bls := PackedFloat64Array()
	while i < tags.size():
		if int(tags[i][0]) == 0 and String(tags[i][1]) == "VERTEX":
			var vx := 0.0
			var vy := 0.0
			var vb := 0.0
			var j := i + 1
			while j < tags.size() and int(tags[j][0]) != 0:
				match int(tags[j][0]):
					10:
						vx = String(tags[j][1]).to_float()
					20:
						vy = String(tags[j][1]).to_float()
					42:
						vb = String(tags[j][1]).to_float()
				j += 1
			pts.append(Vector2(vx, vy))
			bls.append(vb)
			i = j
			continue
		if int(tags[i][0]) == 0 and String(tags[i][1]) == "SEQEND":
			# 跳过 SEQEND 自身的属性
			i += 1
			while i < tags.size() and int(tags[i][0]) != 0:
				i += 1
			break
		if int(tags[i][0]) == 0:
			break
		i += 1
	if pts.size() < 2:
		return [null, i]
	var _unused := doc
	return [EntPolyline.make(pts, bls, (flags & 1) != 0), i]


func _mk_insert(d: Dictionary) -> CadEntity:
	var name := _s(d, 2)
	if name == "":
		return null
	var e := EntInsert.make(name, Vector2(_f(d, 10), _f(d, 20)))
	e.scale = Vector2(_f(d, 41, 1.0), _f(d, 42, 1.0))
	e.rotation = deg_to_rad(_f(d, 50))
	return e


func _mk_ellipse(d: Dictionary) -> CadEntity:
	var c := Vector2(_f(d, 10), _f(d, 20))
	var major := Vector2(_f(d, 11), _f(d, 21))
	var ratio := _f(d, 40, 1.0)
	var a := major.length()
	if a <= Tol.MIN_LEN:
		return null
	var p0 := _f(d, 41, 0.0)
	var p1 := _f(d, 42, TAU)
	if absf(p1 - p0) <= 1.0e-9:
		p1 = p0 + TAU
	return EntEllipse.make(c, a, a * absf(ratio), major.angle(), p0, p1)


func _mk_spline(d: Dictionary) -> CadEntity:
	# 优先取拟合点(11/21)，没有则用控制点(10/20)近似
	var xs := _all(d, 11)
	var ys := _all(d, 21)
	if xs.is_empty():
		xs = _all(d, 10)
		ys = _all(d, 20)
	var pts := PackedVector2Array()
	var n := mini(xs.size(), ys.size())
	for i in range(n):
		pts.append(Vector2(String(xs[i]).to_float(), String(ys[i]).to_float()))
	if pts.size() < 2:
		return null
	var closed := (String(d.get(70, "0")).to_int() & 1) != 0
	return EntSpline.make(pts, closed)


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

func _note(msg: String) -> void:
	# 同一类告警只记一条，避免刷屏
	for w in warnings:
		if String(w) == msg:
			return
	if warnings.size() < 40:
		warnings.append(msg)


## ACI 颜色索引 -> RGB。
## 前 9 个是标准色，250~255 是灰阶；中间 10~249 按 24 个色相组近似。
static func _aci_color(aci: int) -> Color:
	match aci:
		1:
			return Color(1.0, 0.0, 0.0)
		2:
			return Color(1.0, 1.0, 0.0)
		3:
			return Color(0.0, 1.0, 0.0)
		4:
			return Color(0.0, 1.0, 1.0)
		5:
			return Color(0.0, 0.0, 1.0)
		6:
			return Color(1.0, 0.0, 1.0)
		7:
			return Color(1.0, 1.0, 1.0)
		8:
			return Color(0.5, 0.5, 0.5)
		9:
			return Color(0.75, 0.75, 0.75)
	if aci >= 250:
		var g := 1.0 - float(aci - 250) / 6.0 * 0.8
		return Color(g, g, g)
	if aci >= 10 and aci <= 249:
		# 24 个色相 × 10 个明度档
		var idx := aci - 10
		var hue := float(idx / 10) / 24.0
		var shade := float(idx % 10) / 9.0
		var c := Color.from_hsv(hue, 1.0 - shade * 0.6, 1.0 - shade * 0.5)
		return c
	return Color.WHITE
