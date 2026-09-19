class_name EntPolyline
extends CadEntity
## 轻量多段线。对应 DXF 的 LWPOLYLINE。
##
## bulges[i] 描述 points[i] -> points[i+1] 这一段：
##   0 为直线，非 0 为圆弧（bulge = tan(圆心角/4)，正为逆时针）
## 闭合时最后一段由末点回到首点，其 bulge 为 bulges[n-1]。

var poly: GeoPoly = GeoPoly.new()


static func make(pts: PackedVector2Array, bls := PackedFloat64Array(), is_closed := false) -> EntPolyline:
	var e := EntPolyline.new()
	e.type = CadEntity.Type.POLYLINE
	e.poly = GeoPoly.make(pts, bls, is_closed)
	return e


static func make_from_geo(p: GeoPoly) -> EntPolyline:
	var e := EntPolyline.new()
	e.type = CadEntity.Type.POLYLINE
	e.poly = p
	return e


func type_name() -> String:
	return "多段线"


func get_curves() -> Array[GeoCurve]:
	return [poly]


func points() -> PackedVector2Array:
	return poly.points


func bulges() -> PackedFloat64Array:
	return poly.bulges


func is_closed() -> bool:
	return poly.closed


func set_point_count(n: int) -> void:
	if poly.points.size() == n:
		return
	poly.points.resize(n)
	poly.bulges.resize(n)
	invalidate_bbox()


func append_vertex(p: Vector2, bulge := 0.0) -> void:
	poly.points.append(p)
	poly.bulges.append(bulge)
	invalidate_bbox()


func set_vertex(i: int, p: Vector2) -> void:
	if i < 0 or i >= poly.points.size():
		return
	poly.points[i] = p
	invalidate_bbox()


func set_bulge(i: int, b: float) -> void:
	if i < 0 or i >= poly.bulges.size():
		return
	poly.bulges[i] = b
	invalidate_bbox()


func get_grips() -> PackedVector2Array:
	# 每个顶点一个夹点，后接每段中点
	var g := poly.points.duplicate()
	for i in range(poly.span_count()):
		g.append(poly.span(i).midpoint())
	return g


func move_grip(index: int, pos: Vector2) -> void:
	if index < poly.points.size():
		poly.points[index] = pos
		invalidate_bbox()
	# 段中点夹点拖动：把直线段变成圆弧（AutoCAD 行为）
	var span_index := index - poly.points.size()
	if span_index >= 0 and span_index < poly.span_count():
		_apply_midpoint_bulge(span_index, pos)


## 由段中点位置反算 bulge（直线段被拖动后成为圆弧）
func _apply_midpoint_bulge(span_index: int, pos: Vector2) -> void:
	var n := poly.points.size()
	var a := poly.points[span_index]
	var b := poly.points[(span_index + 1) % n]
	var chord := b - a
	var chord_len := chord.length()
	if chord_len <= Tol.MIN_LEN:
		poly.bulges[span_index] = 0.0
		return
	# 中点到弦的垂距，决定圆心角
	var mid := (a + b) * 0.5
	var dir := chord / chord_len
	var left_perp := Vector2(-dir.y, dir.x)
	var h := (pos - mid).dot(left_perp)
	if absf(h) <= Tol.MIN_LEN:
		poly.bulges[span_index] = 0.0
		invalidate_bbox()
		return
	# 由半弦长 d 与垂距 h 求圆心角：tan(theta/4) = h / d（推导见 Bulge 文档）
	var d := chord_len * 0.5
	var b_val := h / d
	# bulge 与垂距同号：正 bulge 的圆弧位于弦右侧，故取负
	poly.bulges[span_index] = -b_val
	invalidate_bbox()


## 拉伸点就是多段线的各个顶点（不含段中点夹点）
func get_stretch_points() -> PackedVector2Array:
	return poly.points.duplicate()


func move_stretch_point(index: int, pos: Vector2) -> void:
	if index >= 0 and index < poly.points.size():
		poly.points[index] = pos
		invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	poly = poly.transformed(xf) as GeoPoly
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make_from_geo(GeoPoly.make(poly.points.duplicate(), poly.bulges.duplicate(), poly.closed))
	_copy_base_to(e)
	return e


## 打散为独立的直线段与圆弧
func explode() -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	for i in range(poly.span_count()):
		var c := poly.span(i)
		if c.kind() == GeoCurve.Kind.SEG:
			var s := c as GeoSeg
			var e := EntLine.make(s.a, s.b)
			_copy_base_to(e)
			out.append(e)
		else:
			var a := c as GeoArc
			var e2 := EntArc.make(a.center, a.radius, a.start_angle, a.end_angle)
			_copy_base_to(e2)
			out.append(e2)
	return out


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["points"] = _pts_to_arr(poly.points)
	var bl := []
	bl.resize(poly.bulges.size())
	for i in range(poly.bulges.size()):
		bl[i] = snappedf(poly.bulges[i], 1.0e-12)
	d["bulges"] = bl
	d["closed"] = poly.closed
	return d


static func from_dict(d: Dictionary) -> EntPolyline:
	var pts := _arr_to_pts(d.get("points", []))
	var bls := PackedFloat64Array()
	var src: Array = d.get("bulges", [])
	bls.resize(src.size())
	for i in range(src.size()):
		bls[i] = float(src[i])
	var e := make(pts, bls, bool(d.get("closed", false)))
	# 必须调用基类恢复公共字段，否则图层/颜色/线宽会在存读档与撤销恢复时丢失
	e.read_base_fields(d)
	return e
