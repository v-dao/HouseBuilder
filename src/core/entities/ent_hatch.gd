class_name EntHatch
extends CadEntity
## 图案填充。对应 DXF 的 HATCH。
##
## 用途：建筑制图中的材料图例（混凝土、砖砌体、夯实土壤……），
## 以及剖面图中被剖切构件的实心填充（poché）。
##
## 几何由「边界轮廓 + 图例名 + 比例 + 角度」推导，不存储填充线本身
## —— 这样边界改了填充会自动跟着变（关联填充），且文件体积小。
## 生成结果按边界与参数做缓存，避免每帧重算。

## 外轮廓（世界坐标，闭合）
var boundary: PackedVector2Array = PackedVector2Array()
## 图例名，取自 GbHatch.library()
var pattern_name: String = "钢筋混凝土"
## 图案比例（相对默认），用于调整疏密
var pattern_scale: float = 1.0
## 附加旋转（度）
var angle_deg: float = 0.0
## 图案相位原点。为 (0,0) 时以边界包围盒左下角为基准。
var origin: Vector2 = Vector2.ZERO
## 实心填充（剖切到的墙体用）。为真时忽略图案，直接填充轮廓。
var solid: bool = false

# --- 缓存 ---
var _cache: PackedVector2Array = PackedVector2Array()
var _cache_key: String = ""


static func make(b: PackedVector2Array, pattern := "钢筋混凝土") -> EntHatch:
	var e := EntHatch.new()
	e.type = CadEntity.Type.HATCH
	e.boundary = b
	e.pattern_name = pattern
	return e


## 用图元的曲线构造边界。只有**闭合**的图元才能作为填充边界。
static func from_entity(e: CadEntity, pattern := "钢筋混凝土") -> EntHatch:
	var pts := PackedVector2Array()
	for c in e.get_curves():
		if c.kind() == GeoCurve.Kind.ARC:
			# 圆可以作为边界；非整圆的圆弧不行
			var a := c as GeoArc
			if not a.is_full_circle():
				continue
			pts = a.tessellate(maxf(a.radius * 0.002, 0.05))
			break
		if c.kind() == GeoCurve.Kind.POLY:
			var poly := c as GeoPoly
			var raw := poly.points.duplicate()
			# 闭合的标志有两种：closed 标记，或首尾点重合
			var is_closed := poly.closed
			if not is_closed and raw.size() > 2 \
					and raw[0].distance_to(raw[raw.size() - 1]) <= Tol.POINT:
				is_closed = true
			if is_closed:
				pts = raw
				break
			# 开口多段线不能作为边界
			return null
	if pts.size() < 3:
		return null
	# 去掉末尾与首点重合的点，内部统一按"不重复首点"处理
	while pts.size() > 1 and pts[0].distance_to(pts[pts.size() - 1]) <= Tol.POINT:
		pts.remove_at(pts.size() - 1)
	var h := make(pts, pattern)
	h.layer = e.layer
	h.aci = e.aci
	h.color = e.color
	return h


func type_name() -> String:
	return "填充"


## 生成填充线段（世界坐标，扁平端点对）。
## 结果按「边界 + 参数 + 文档出图比例」缓存。
func pattern_segments() -> PackedVector2Array:
	var key := _make_key()
	if key == _cache_key:
		return _cache
	_cache = GbHatch.generate(boundary, GbHatch.layers_of(pattern_name),
		plot_scale(), pattern_scale, angle_deg, origin)
	_cache_key = key
	return _cache


func _make_key() -> String:
	var s := "%s|%.4f|%.4f|%.4f|%.4f|%s" % [pattern_name, pattern_scale, angle_deg,
		plot_scale(), boundary.size(), str(boundary.size())]
	# 边界坐标变化必须让缓存失效：用包围盒与首末点做指纹
	if boundary.size() > 0:
		var bb := GbHatch._bbox(boundary)
		s += "|%.4f,%.4f,%.4f,%.4f" % [bb.position.x, bb.position.y, bb.size.x, bb.size.y]
		s += "|%.4f,%.4f" % [boundary[0].x, boundary[0].y]
	return s


## 填充本身以线段参与渲染与几何运算。
## 包成多段线是为了复用统一的偏移/修剪/捕捉能力。
func get_curves() -> Array[GeoCurve]:
	if solid:
		return [GeoPoly.make(boundary, PackedFloat64Array(), true)]
	return [GeoPoly.make(pattern_segments(), PackedFloat64Array(), false)]


## 实心填充时由渲染器直接填多边形，故单独暴露轮廓
func is_solid() -> bool:
	return solid


func boundary_closed() -> PackedVector2Array:
	var out := boundary.duplicate()
	if out.size() > 1 and out[0].distance_to(out[out.size() - 1]) > Tol.POINT:
		out.append(out[0])
	return out


func get_bbox() -> Rect2:
	if boundary.size() < 3:
		return Rect2()
	if solid:
		return GbHatch._bbox(boundary)
	var segs := pattern_segments()
	if segs.size() < 2:
		return GbHatch._bbox(boundary)
	var mn := segs[0]
	var mx := segs[0]
	for p in segs:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	return Rect2(mn, mx - mn)


## 拾取判定：落在边界内即算命中（填充线很密，按线判定会误命中）
func distance_to(p: Vector2) -> float:
	if boundary.size() >= 3 and GbHatch.point_in_polygon(p, boundary):
		return 0.0
	return super.distance_to(p)


func get_grips() -> PackedVector2Array:
	return boundary.duplicate()


func get_stretch_points() -> PackedVector2Array:
	return boundary.duplicate()


func move_grip(i: int, p: Vector2) -> void:
	if i >= 0 and i < boundary.size():
		boundary[i] = p
		_cache_key = ""
	invalidate_bbox()


func transform_by(xf: Transform2D) -> void:
	for i in range(boundary.size()):
		boundary[i] = xf * boundary[i]
	origin = xf * origin
	# 角度按变换的旋转量累加（GB 图例的角度是相对图纸的）
	angle_deg += rad_to_deg(xf.get_rotation())
	_cache_key = ""
	invalidate_bbox()


func clone() -> CadEntity:
	var e := make(boundary.duplicate(), pattern_name)
	e.pattern_scale = pattern_scale
	e.angle_deg = angle_deg
	e.origin = origin
	e.solid = solid
	_copy_base_to(e)
	return e


## 打散为填充线段
func explode() -> Array[CadEntity]:
	if solid:
		var e0 := EntPolyline.make(boundary.duplicate(), PackedFloat64Array(), true)
		_copy_base_to(e0)
		return [e0]
	var segs := pattern_segments()
	if segs.size() < 2:
		return []
	var e := EntPolyline.make(segs, PackedFloat64Array(), false)
	_copy_base_to(e)
	return [e]


func feature_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in boundary:
		out.append({"point": p, "type": SnapType.ENDPOINT})
	return out


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["pattern_name"] = pattern_name
	d["pattern_scale"] = snappedf(pattern_scale, 1e-6)
	d["angle_deg"] = snappedf(angle_deg, 1e-9)
	d["solid"] = solid
	_put_v2(d, "origin", origin)
	d["boundary"] = _pts_to_arr(boundary)
	return d


static func from_dict(d: Dictionary) -> EntHatch:
	var e := EntHatch.new()
	e.type = CadEntity.Type.HATCH
	e.read_base_fields(d)
	e.pattern_name = String(d.get("pattern_name", "钢筋混凝土"))
	e.pattern_scale = float(d.get("pattern_scale", 1.0))
	e.angle_deg = float(d.get("angle_deg", 0.0))
	e.origin = _v2(d, "origin")
	e.solid = bool(d.get("solid", false))
	e.boundary = _arr_to_pts(d.get("boundary", []))
	return e
