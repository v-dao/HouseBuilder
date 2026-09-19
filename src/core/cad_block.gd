class_name CadBlock
extends RefCounted
## 块定义。对应 DXF 的 BLOCK 表项。
## 块内的图元坐标以块基点（base_point）为原点。

var name: String = ""
var base_point: Vector2 = Vector2.ZERO
var description: String = ""
var entities: Array[CadEntity] = []
## 属性定义（属性块的字段声明）。属性块在图纸目录、门窗表里用途很广。
var attribute_defs: Array[Dictionary] = []
## 内置图库块（不可被用户编辑）
var builtin: bool = false


static func make(p_name: String, base := Vector2.ZERO) -> CadBlock:
	var b := CadBlock.new()
	b.name = p_name
	b.base_point = base
	return b


func add(e: CadEntity) -> void:
	e.owner_block = name
	entities.append(e)


func duplicate_block() -> CadBlock:
	var b := CadBlock.make(name, base_point)
	b.description = description
	b.builtin = builtin
	b.attribute_defs = attribute_defs.duplicate(true)
	for e in entities:
		var c := e.clone()
		if c != null:
			b.add(c)
	return b


func get_bbox() -> Rect2:
	if entities.is_empty():
		return Rect2()
	var bb := entities[0].get_bbox()
	for i in range(1, entities.size()):
		bb = bb.merge(entities[i].get_bbox())
	return bb


func to_dict() -> Dictionary:
	var ents := []
	for e in entities:
		ents.append(e.to_dict())
	return {
		"name": name,
		"base_point": [base_point.x, base_point.y],
		"description": description,
		"builtin": builtin,
		"attribute_defs": attribute_defs.duplicate(true),
		"entities": ents,
	}
