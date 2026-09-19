class_name QuadTree
extends RefCounted
## 松散式四叉树空间索引。
##
## 用途：视口剔除、拾取、框选、捕捉候选集的快速筛选。
## 十万级图元时若每次遍历全表，框选与渲染剔除都会成为瓶颈。
##
## 插入策略：把图元放进**能完整容纳其包围盒的最深节点**。
## 这样查询的正确性很容易证明：若图元 bbox 与查询矩形相交，
## 而图元存放在节点 N（N ⊇ 图元 bbox），则 N 必与查询矩形相交，
## 故 N 一定会被访问到，图元不会被漏掉。因此无需"松散边界 + 重复存储"的复杂方案。
##
## 超出 MAX_DEPTH 或跨子节点边界的图元留在当前节点，保证不会无限细分。

const MAX_ITEMS := 8
const MAX_DEPTH := 8

var bounds: Rect2 = Rect2()
var _items: Array[CadEntity] = []
var _children: Array[QuadTree] = []
var _depth: int = 0


static func build(entities: Array[CadEntity], area: Rect2) -> QuadTree:
	var q := QuadTree.new()
	q.bounds = _square_area(area)
	q.rebuild(entities)
	return q


## 把区域扩成正方形，避免长条形图纸导致切分失衡
static func _square_area(r: Rect2) -> Rect2:
	var c := r.position + r.size * 0.5
	var s := maxf(maxf(r.size.x, r.size.y), 1.0) * 1.02
	return Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s))


static func _make_child(b: Rect2, d: int) -> QuadTree:
	var q := QuadTree.new()
	q.bounds = b
	q._depth = d
	return q


func clear() -> void:
	_items.clear()
	_children.clear()


## 重建索引。区域为图元总包围盒时用 build()，否则用本方法配合手动设定 bounds。
func rebuild(entities: Array[CadEntity]) -> void:
	clear()
	for e in entities:
		insert(e)


func insert(e: CadEntity) -> void:
	_insert(e, e.get_bbox())


func _insert(e: CadEntity, bb: Rect2) -> void:
	# 还有子节点时先尝试下放
	if not _children.is_empty():
		for c in _children:
			if c.bounds.encloses(bb):
				c._insert(e, bb)
				return
		_items.append(e)
		return
	_items.append(e)
	if _items.size() > MAX_ITEMS and _depth < MAX_DEPTH:
		_split()


func _split() -> void:
	var h := bounds.size * 0.5
	var o := bounds.position
	# 四分：左下、右下、左上、右上（顺序无关，但要互不重叠且并集为父节点）
	_children = [
		_make_child(Rect2(o, h), _depth + 1),
		_make_child(Rect2(o + Vector2(h.x, 0.0), h), _depth + 1),
		_make_child(Rect2(o + Vector2(0.0, h.y), h), _depth + 1),
		_make_child(Rect2(o + h, h), _depth + 1),
	]
	# 重新分配：能完整落入某个子节点的就下放，其余留在本节点
	var keep: Array[CadEntity] = []
	for e in _items:
		var bb := e.get_bbox()
		var placed := false
		for c in _children:
			if c.bounds.encloses(bb):
				c._insert(e, bb)
				placed = true
				break
		if not placed:
			keep.append(e)
	_items = keep


## 移除一个图元（按包围盒定位到可能存放的节点）
func remove(e: CadEntity) -> bool:
	var bb := e.get_bbox()
	if not bounds.encloses(bb):
		# 图元缩小到原区域外，退化为全树搜索
		return _remove_recursive(e)
	var node := _locate(bb)
	if node == null:
		return false
	var idx := node._items.find(e)
	if idx < 0:
		return false
	node._items.remove_at(idx)
	return true


func _remove_recursive(e: CadEntity) -> bool:
	var idx := _items.find(e)
	if idx >= 0:
		_items.remove_at(idx)
		return true
	for c in _children:
		if c._remove_recursive(e):
			return true
	return false


## 找到能容纳 bb 的最深节点
func _locate(bb: Rect2) -> QuadTree:
	if not bounds.encloses(bb):
		return null
	for c in _children:
		if c.bounds.encloses(bb):
			var r := c._locate(bb)
			if r != null:
				return r
	return self


## 查询与矩形相交的图元。返回的是候选集，调用方仍需做精确判定。
func query_rect(r: Rect2) -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	_query_rect(r, out)
	return out


func _query_rect(r: Rect2, out: Array[CadEntity]) -> void:
	if not bounds.intersects(r):
		return
	for e in _items:
		if e.get_bbox().intersects(r):
			out.append(e)
	for c in _children:
		c._query_rect(r, out)


## 查询包含给定点的图元候选
func query_point(p: Vector2, tol: float = 0.0) -> Array[CadEntity]:
	var r := Rect2(p - Vector2(tol, tol), Vector2(tol, tol) * 2.0)
	return query_rect(r)


## 查询与给定线段相交的图元候选（栅栏选用）
func query_seg(a: Vector2, b: Vector2) -> Array[CadEntity]:
	return query_rect(Rect2(a, Vector2.ZERO).merge(Rect2(b, Vector2.ZERO)).grow(Tol.POINT))


## 遍历全部图元（不用于高频路径）
func all() -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	_all(out)
	return out


func _all(out: Array[CadEntity]) -> void:
	for e in _items:
		out.append(e)
	for c in _children:
		c._all(out)


## 统计节点数与图元数，用于性能分析
func stats() -> Dictionary:
	var nodes := 1
	var items := _items.size()
	var max_depth := _depth
	for c in _children:
		var s := c.stats()
		nodes += int(s["nodes"])
		items += int(s["items"])
		max_depth = maxi(max_depth, int(s["max_depth"]))
	return {"nodes": nodes, "items": items, "max_depth": max_depth, "children": _children.size()}
