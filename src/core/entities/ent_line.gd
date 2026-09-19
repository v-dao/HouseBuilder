class_name EntLine
extends CadEntity
## 直线段。对应 DXF 的 LINE（组码 10/11）。

var p0: Vector2 = Vector2.ZERO
var p1: Vector2 = Vector2.ZERO


static func make(a: Vector2, b: Vector2) -> EntLine:
	var e := EntLine.new()
	e.type = CadEntity.Type.LINE
	e.p0 = a
	e.p1 = b
	return e


func type_name() -> String:
	return "直线"


func _build_curves() -> Array[GeoCurve]:
	return [GeoSeg.make(p0, p1)]


## 直线是最常见的图元，覆写以消除每帧的临时数组分配。
## 入桶的是模型坐标（与分桶约定一致），不做屏幕变换。
func emit_segments(out: PackedVector2Array, _sagitta: float) -> void:
	out.append(p0)
	out.append(p1)


func get_grips() -> PackedVector2Array:
	return PackedVector2Array([p0, (p0 + p1) * 0.5, p1])


func move_grip(index: int, pos: Vector2) -> void:
	match index:
		0:
			p0 = pos
		1:
			# 夹点 1 是中点：整体平移（AutoCAD 行为）
			var delta := pos - (p0 + p1) * 0.5
			p0 += delta
			p1 += delta
		2:
			p1 = pos
	invalidate_bbox()


## 拉伸点只有两个端点。夹点里的"中点"是移动整条线的辅助点，不参与拉伸。
func get_stretch_points() -> PackedVector2Array:
	return PackedVector2Array([p0, p1])


func move_stretch_point(index: int, pos: Vector2) -> void:
	if index == 0:
		p0 = pos
	elif index == 1:
		p1 = pos
	invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	p0 = xf * p0
	p1 = xf * p1
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make(p0, p1)
	_copy_base_to(e)
	return e


func explode() -> Array[CadEntity]:
	return []


func angle() -> float:
	return (p1 - p0).angle()


func length() -> float:
	return p0.distance_to(p1)


func to_dict() -> Dictionary:
	var d := super.to_dict()
	_put_v2(d, "p0", p0)
	_put_v2(d, "p1", p1)
	return d


static func from_dict(d: Dictionary) -> EntLine:
	var e := EntLine.new()
	e.type = CadEntity.Type.LINE
	e.read_base_fields(d)
	e.p0 = _v2(d, "p0")
	e.p1 = _v2(d, "p1")
	return e
