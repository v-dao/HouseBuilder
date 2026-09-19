class_name EntInsert
extends CadEntity
## 块引用。对应 DXF 的 INSERT。
##
## 块的价值在于「一处定义、多处引用」：改块定义，所有引用同步更新。
## 建筑图里的门窗、洁具、家具、图框符号都适合做成块。
##
## 与普通图元的区别：它自身没有几何，几何来自块定义经变换后的结果。
## 因此：
##   · get_curves() 返回变换后的块内图元曲线（供捕捉、拾取、求交使用）
##   · 渲染器需要单独处理，因为块内图元可能各有图层与颜色（随块 BYBLOCK）

var block_name: String = ""
var position: Vector2 = Vector2.ZERO
## 缩放（X/Y 可不等，但建筑图块通常等比）
var scale: Vector2 = Vector2.ONE
var rotation: float = 0.0
## 属性值：属性名 -> 文本。属性块的字段值存在这里。
var attributes: Dictionary = {}


static func make(name: String, pos: Vector2) -> EntInsert:
	var e := EntInsert.new()
	e.type = CadEntity.Type.INSERT
	e.block_name = name
	e.position = pos
	return e


func type_name() -> String:
	return "块引用(%s)" % block_name


## 本引用的变换：先按块基点平移，再缩放、旋转，最后落到插入点
func insert_transform() -> Transform2D:
	var blk := get_block()
	var base := blk.base_point if blk != null else Vector2.ZERO
	var xf := Transform2D(rotation, position)
	xf = xf.scaled(scale)
	xf = xf.translated(-base)
	return xf


func get_block() -> CadBlock:
	var doc := get_document()
	if doc == null:
		return null
	return doc.get_block(block_name)


## 块内的图元（未变换）。块不存在时返回空。
func block_entities() -> Array[CadEntity]:
	var blk := get_block()
	if blk == null:
		return []
	return blk.entities


## 返回变换后的块内图元曲线。供捕捉、拾取、几何运算使用。
func get_curves() -> Array[GeoCurve]:
	var out: Array[GeoCurve] = []
	var xf := insert_transform()
	for e in block_entities():
		if not e.visible:
			continue
		for c in e.get_curves():
			var t := c.transformed(xf)
			if t != null:
				out.append(t)
	return out


func get_bbox() -> Rect2:
	var ents := block_entities()
	if ents.is_empty():
		return Rect2(position, Vector2.ZERO)
	var xf := insert_transform()
	var bb := _xform_rect(ents[0].get_bbox(), xf)
	for i in range(1, ents.size()):
		bb = bb.merge(_xform_rect(ents[i].get_bbox(), xf))
	return bb


static func _xform_rect(r: Rect2, xf: Transform2D) -> Rect2:
	var pts := [
		xf * r.position,
		xf * (r.position + Vector2(r.size.x, 0)),
		xf * (r.position + r.size),
		xf * (r.position + Vector2(0, r.size.y)),
	]
	var mn: Vector2 = pts[0]
	var mx: Vector2 = pts[0]
	for p in pts:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	return Rect2(mn, mx - mn)


## 块内文字注记经变换后输出。属性值在此替换。
func get_annotation_texts() -> Array:
	var out: Array = []
	var xf := insert_transform()
	var rot := rotation
	for e in block_entities():
		if not e.visible:
			continue
		for a in e.get_annotation_texts():
			var pos: Vector2 = a.get("position", Vector2.ZERO)
			var txt := String(a.get("text", ""))
			# 属性块：文字若与属性名同名，则用实际属性值替换
			if attributes.has(txt):
				txt = String(attributes[txt])
			var h := float(a.get("height", 3.5)) * absf(scale.y)
			out.append({
				"text": txt,
				"position": xf * pos,
				"rotation": float(a.get("rotation", 0.0)) + rot,
				"height": h,
				"style": String(a.get("style", "仿宋_3.5")),
				"h_align": int(a.get("h_align", EntText.HAlign.LEFT)),
				"v_align": int(a.get("v_align", EntText.VAlign.BASELINE)),
			})
	return out


func get_grips() -> PackedVector2Array:
	return PackedVector2Array([position])


func get_stretch_points() -> PackedVector2Array:
	return PackedVector2Array([position])


func move_grip(_i: int, p: Vector2) -> void:
	position = p
	invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	position = xf * position
	var s := xf.x.length()
	scale *= s
	rotation += xf.get_rotation()
	invalidate_bbox()


## 打散为块内图元的副本（已应用插入变换）。
## 若块带属性，同时把属性值补成文字图元。
func explode() -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	var xf := insert_transform()
	for e in block_entities():
		var c := e.clone()
		if c == null:
			continue
		c.handle = 0
		c.transform_by(xf)
		# 随块的颜色：块内图元若标记 BYBLOCK，则取引用自身的颜色
		if c.aci == 0:
			c.aci = aci
			c.color = color
		out.append(c)
	# 属性值落成文字
	for a in get_annotation_texts():
		var t := EntText.make(a["position"], String(a["text"]), float(a["height"]), float(a["rotation"]))
		t.text_style = String(a["style"])
		t.h_align = int(a["h_align"])
		t.v_align = int(a["v_align"])
		t.layer = layer
		t.aci = 256
		out.append(t)
	return out


func feature_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = [{"point": position, "type": SnapType.INSERTION}]
	for c in get_curves():
		for f in c.feature_points():
			out.append(f)
	return out


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["block_name"] = block_name
	_put_v2(d, "position", position)
	d["scale"] = [snappedf(scale.x, 1e-9), snappedf(scale.y, 1e-9)]
	d["rotation"] = snappedf(rotation, 1e-9)
	if not attributes.is_empty():
		d["attributes"] = attributes.duplicate()
	return d


static func from_dict(d: Dictionary) -> EntInsert:
	var e := EntInsert.new()
	e.type = CadEntity.Type.INSERT
	e.read_base_fields(d)
	e.block_name = String(d.get("block_name", ""))
	e.position = _v2(d, "position")
	if d.has("scale"):
		var sc: Array = d["scale"]
		e.scale = Vector2(float(sc[0]), float(sc[1]))
	e.rotation = float(d.get("rotation", 0.0))
	var attrs = d.get("attributes")
	if attrs is Dictionary:
		e.attributes = (attrs as Dictionary).duplicate()
	return e
