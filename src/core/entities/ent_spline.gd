class_name EntSpline
extends CadEntity
## 样条曲线。对应 DXF 中带拟合点的 SPLINE。
## 曲线严格通过各个型值点，用于曲线道路、等高线、异形造型。

var spline: GeoSpline = GeoSpline.new()


static func make(pts: PackedVector2Array, is_closed := false) -> EntSpline:
	var e := EntSpline.new()
	e.type = CadEntity.Type.SPLINE
	e.spline = GeoSpline.make(pts, is_closed)
	return e


static func make_from_geo(s: GeoSpline) -> EntSpline:
	var e := EntSpline.new()
	e.type = CadEntity.Type.SPLINE
	e.spline = s
	return e


func type_name() -> String:
	return "样条曲线"


func _build_curves() -> Array[GeoCurve]:
	return [spline]


func fit_points() -> PackedVector2Array:
	return spline.fit_points


func is_closed() -> bool:
	return spline.closed


func get_grips() -> PackedVector2Array:
	# 每个型值点一个夹点，后接每一段的中点夹点
	var g := spline.fit_points.duplicate()
	for i in range(spline.segment_count()):
		g.append(spline._seg_point(i, 0.5))
	return g


func move_grip(index: int, pos: Vector2) -> void:
	if index < spline.fit_points.size():
		spline.fit_points[index] = pos
		invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	spline = spline.transformed(xf) as GeoSpline
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make_from_geo(GeoSpline.make(spline.fit_points.duplicate(), spline.closed))
	e.spline.tension = spline.tension
	_copy_base_to(e)
	return e


## 打散为折线（按合理精度离散）
func explode() -> Array[CadEntity]:
	var pts := spline.tessellate(0.5)
	if pts.size() < 2:
		return []
	var e := EntPolyline.make(pts)
	_copy_base_to(e)
	return [e]


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["fit_points"] = _pts_to_arr(spline.fit_points)
	d["closed"] = spline.closed
	d["tension"] = snappedf(spline.tension, 1e-6)
	return d


static func from_dict(d: Dictionary) -> EntSpline:
	var e := EntSpline.new()
	e.type = CadEntity.Type.SPLINE
	e.read_base_fields(d)
	e.spline = GeoSpline.make(_arr_to_pts(d.get("fit_points", [])), bool(d.get("closed", false)))
	e.spline.tension = float(d.get("tension", 0.5))
	return e
