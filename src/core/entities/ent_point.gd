class_name EntPoint
extends CadEntity
## 点。对应 DXF 的 POINT。
##
## 显示方式对应 AutoCAD 的 PDMODE：本类固定用一种"圆内十字"的样式，
## 屏幕尺寸恒定（不随缩放变化），保证任何缩放级别下都清晰可点选。

var position: Vector2 = Vector2.ZERO


static func make(p: Vector2) -> EntPoint:
	var e := EntPoint.new()
	e.type = CadEntity.Type.POINT
	e.position = p
	return e


func type_name() -> String:
	return "点"


## 点没有线状几何。返回一条退化线段，让捕捉与拾取的距离计算能自然落到该点上。
func _build_curves() -> Array[GeoCurve]:
	return [GeoSeg.make(position, position)]


func get_grips() -> PackedVector2Array:
	return PackedVector2Array([position])


func move_grip(index: int, pos: Vector2) -> void:
	if index == 0:
		position = pos
	invalidate_bbox()


func get_bbox() -> Rect2:
	# 给一个极小但非零的包围盒，避免在视口剔除时被判为永不显示
	return Rect2(position - Vector2(0.5, 0.5), Vector2(1.0, 1.0))


func distance_to(p: Vector2) -> float:
	return position.distance_to(p)


func feature_points() -> Array[Dictionary]:
	return [{"point": position, "type": SnapType.NODE}]


func transform_by(xf: Transform2D) -> void:
	position = xf * position
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make(position)
	_copy_base_to(e)
	return e


func explode() -> Array[CadEntity]:
	return []


func to_dict() -> Dictionary:
	var d := super.to_dict()
	_put_v2(d, "position", position)
	return d


static func from_dict(d: Dictionary) -> EntPoint:
	var e := EntPoint.new()
	e.type = CadEntity.Type.POINT
	e.read_base_fields(d)
	e.position = _v2(d, "position")
	return e
