class_name CadSelection
extends RefCounted
## 选择集。所有编辑命令的操作对象。
##
## 拾取与框选都先经四叉树取候选，再做精确判定，避免遍历全表。

var items: Array[CadEntity] = []


func clear() -> void:
	items.clear()


func add(e: CadEntity) -> void:
	if not items.has(e):
		items.append(e)


func add_all(list: Array) -> void:
	for e in list:
		add(e)


func remove(e: CadEntity) -> void:
	items.erase(e)


func toggle(e: CadEntity) -> void:
	if items.has(e):
		items.erase(e)
	else:
		items.append(e)


func has(e: CadEntity) -> bool:
	return items.has(e)


func size() -> int:
	return items.size()


func is_empty() -> bool:
	return items.is_empty()


## 整体包围盒
func bbox() -> Rect2:
	if items.is_empty():
		return Rect2()
	var bb := items[0].get_bbox()
	for i in range(1, items.size()):
		bb = bb.merge(items[i].get_bbox())
	return bb


## 包围盒中心，作为旋转/缩放的默认基点
func center() -> Vector2:
	var bb := bbox()
	return bb.position + bb.size * 0.5


# ---------------------------------------------------------------------------
# 拾取与框选
# ---------------------------------------------------------------------------

## 单点拾取：返回容差内最近的图元。
## 距离相同时取后加入者（与 CAD「后画的对象在上层」的习惯一致）。
static func pick(doc: CadDocument, index: QuadTree, p: Vector2, tol: float,
		layer_filter := true) -> CadEntity:
	var cands := _candidates(doc, index, Rect2(p - Vector2(tol, tol), Vector2(tol, tol) * 2.0))
	var best: CadEntity = null
	var best_d := tol
	for e in cands:
		if layer_filter and not _selectable(doc, e):
			continue
		var d := e.distance_to(p)
		if d <= best_d + Tol.POINT:
			best_d = d
			best = e
	return best


## 窗选：图元必须**完全**落在矩形内
static func window_select(doc: CadDocument, index: QuadTree, r: Rect2) -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	for e in _candidates(doc, index, r):
		if not _selectable(doc, e):
			continue
		if r.encloses(e.get_bbox()):
			out.append(e)
	return out


## 交叉选：图元只要与矩形**相交**即被选中
static func crossing_select(doc: CadDocument, index: QuadTree, r: Rect2) -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	for e in _candidates(doc, index, r):
		if not _selectable(doc, e):
			continue
		if _entity_touches_rect(e, r):
			out.append(e)
	return out


## 栅栏选：图元与折线栅栏相交即被选中
static func fence_select(doc: CadDocument, index: QuadTree, fence: PackedVector2Array) -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	if fence.size() < 2:
		return out
	var r := Rect2(fence[0], Vector2.ZERO)
	for i in range(1, fence.size()):
		r = r.expand(fence[i])
	for e in _candidates(doc, index, r):
		if not _selectable(doc, e):
			continue
		if _entity_touches_fence(e, fence):
			out.append(e)
	return out


static func _candidates(doc: CadDocument, index: QuadTree, r: Rect2) -> Array[CadEntity]:
	if index != null:
		return index.query_rect(r)
	# 索引不可用时退化为全表扫描
	var out: Array[CadEntity] = []
	for e in doc.entities:
		if e.get_bbox().intersects(r):
			out.append(e)
	return out


static func _selectable(doc: CadDocument, e: CadEntity) -> bool:
	if not e.visible:
		return false
	var l := doc.get_layer(e.layer)
	return l == null or l.is_selectable()


## 图元是否与矩形接触（含完全在内、穿越边界、部分在内）
static func _entity_touches_rect(e: CadEntity, r: Rect2) -> bool:
	var bb := e.get_bbox()
	if not bb.intersects(r):
		return false
	if r.encloses(bb):
		return true
	for c in CurveOps.decompose_all(e):
		for pts in _curve_polys(c):
			for i in range(pts.size() - 1):
				if _seg_rect_hit(pts[i], pts[i + 1], r):
					return true
	return false


static func _entity_touches_fence(e: CadEntity, fence: PackedVector2Array) -> bool:
	for c in CurveOps.decompose_all(e):
		for pts in _curve_polys(c):
			for i in range(pts.size() - 1):
				for j in range(fence.size() - 1):
					var sa := GeoSeg.make(pts[i], pts[i + 1])
					var sb := GeoSeg.make(fence[j], fence[j + 1])
					if sa.intersect_seg(sb)["hit"]:
						return true
	return false


## 把曲线离散成折线（圆弧/椭圆/样条需要细分）
static func _curve_polys(c: GeoCurve) -> Array[PackedVector2Array]:
	match c.kind():
		GeoCurve.Kind.SEG:
			var s := c as GeoSeg
			return [PackedVector2Array([s.a, s.b])]
		GeoCurve.Kind.ARC:
			return [(c as GeoArc).tessellate(0.05)]
		GeoCurve.Kind.POLY:
			return [(c as GeoPoly).tessellate(0.05)]
		_:
			return [c.tessellate(maxf(c.bbox().size.length() * 1.0e-4, 0.01))]


## 线段与矩形是否接触（含线段完全在内、穿越边界）
static func _seg_rect_hit(a: Vector2, b: Vector2, r: Rect2) -> bool:
	if r.has_point(a) or r.has_point(b):
		return true
	var c0 := r.position
	var c1 := r.position + Vector2(r.size.x, 0)
	var c2 := r.position + r.size
	var c3 := r.position + Vector2(0, r.size.y)
	var corners := [c0, c1, c2, c3]
	var s := GeoSeg.make(a, b)
	for i in range(4):
		var e := GeoSeg.make(corners[i], corners[(i + 1) % 4])
		if s.intersect_seg(e)["hit"]:
			return true
	return false


# ---------------------------------------------------------------------------
# 批量变换
# ---------------------------------------------------------------------------

## 对选中的图元施加变换。调用方负责开启/提交事务。
func apply_transform(doc: CadDocument, xf: Transform2D) -> void:
	for e in items:
		doc.mark_modified(e)
		e.transform_by(xf)
		doc.touch(e)


func translate(doc: CadDocument, delta: Vector2) -> void:
	apply_transform(doc, Transform2D(0.0, delta))


## 绕基点旋转：xf(v) = base + R·(v - base)，故 origin = base - R·base
func rotate(doc: CadDocument, base: Vector2, angle: float) -> void:
	var r := Transform2D(angle, Vector2.ZERO)
	apply_transform(doc, Transform2D(r.x, r.y, base - r * base))


## 绕基点缩放：xf(v) = factor·v + base·(1 - factor)
func scale(doc: CadDocument, base: Vector2, factor: float) -> void:
	var xf := Transform2D(Vector2(factor, 0.0), Vector2(0.0, factor), base * (1.0 - factor))
	apply_transform(doc, xf)


## 关于由 p1、p2 决定的直线做镜像。
## 做法：平移到基点并转到 X 轴 -> 关于 X 轴翻转 -> 逆变换回去。
## 逆变换必须用 affine_inverse()，手写 T(-ang, -p1) 是错的（那不是逆）。
func mirror(doc: CadDocument, p1: Vector2, p2: Vector2) -> void:
	var d := p2 - p1
	if d.length() <= Tol.MIN_LEN:
		return
	var fwd := Transform2D(d.angle(), p1)
	var flip := Transform2D(Vector2(1.0, 0.0), Vector2(0.0, -1.0), Vector2.ZERO)
	apply_transform(doc, fwd * flip * fwd.affine_inverse())
