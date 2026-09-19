class_name SpatialIndex
extends RefCounted
## 扁平网格空间索引。
##
## 用途：视口剔除、拾取、框选、捕捉候选集的快速筛选。
##
## ## 为什么不用四叉树
##
## 纯 GDScript 里层次结构的开销是**解释器成本**而非算法成本：每个图元每一层
## 都要一次下潜判定，且每次切分还要把已放置的图元取出来重插一遍。实测十万图元
## 建库 355ms，其中九成花在下潜与切分上。所以"批量建树"省不下来（层数没变），
## 真正的杠杆是**减少层数**。
##
## 在真实基准数据（120m 见方、10 万条 500~6000mm 线段）上实测：
##
## | 结构 | 建库 | 单次拾取 | 单次交叉选 |
## |---|---|---|---|
## | 四叉树 | 355 ms | 2309 us | 3895 us |
## | 本索引 | 116 ms | 345 us | 1665 us |
##
## 三项全胜，且命中结果完全一致。详见 docs/性能实测与瓶颈分析.md。
##
## ## 登记与查询
##
## 图元放进**包围盒中心所在的那一格**（不是覆盖到的每一格）：每个图元只登记
## 一次，建成更快，查询结果也天然不重复 —— 重叠登记会让 window_select 返回
## 重复图元，必须额外去重。
##
## 查询时把查询矩形**向外扩 _expand 格**。设格边长 s，格内图元的最长半轴为 h，
## 取 _expand = ceil(h / s)：相交点 P ∈ 查询矩形 Q ∩ 图元包围盒，图元中心 C 到 P
## 的距离不超过 h，故 C 落在 Q 外扩 h 的范围内；而 ceil(h/s) 格必定覆盖 h 的距离，
## 于是含 C 的格子必被访问到，不会漏结果。
##
## 半轴超过 MAX_EXPAND 格边长的**极端长图元**（跨越整张图的墙、尺寸线等）进
## _oversized 清单，每次查询单独做包围盒判定。否则一条长线会把 _expand 顶得
## 很大，让**所有**查询都退化成扫描大片格子。这样代价被隔离在少数几个图元上。

## 目标每格图元数。越大格越少、每格候选越多。
const TARGET_PER_CELL := 8
const MIN_AXIS_CELLS := 8
const MAX_AXIS_CELLS := 512
## 外扩格数上限。半轴超过 MAX_EXPAND × 格边长的图元进超规格清单。
## 取 4 是权衡：查询最多访问 (2×4+1)² = 81 格，同时能收下绝大多数常规图元。
const MAX_EXPAND := 4

## 覆盖区域（调试与估算用）
var bounds: Rect2 = Rect2()

## 格边长与格网原点
var _side := 1000.0
var _origin := Vector2.ZERO
## 查询外扩格数与格内图元的最长半轴
var _expand := 1
var _max_half := 0.0

## Vector2i 格号 -> Array[CadEntity]
var _cells: Dictionary = {}
## 极端长图元，任何查询都单独判定
var _oversized: Array[CadEntity] = []
## 已登记图元数（每个图元只计一次）
var _count := 0


static func build(entities: Array[CadEntity], area: Rect2) -> SpatialIndex:
	var ix := SpatialIndex.new()
	ix.bounds = area
	ix._plan(entities.size(), area)
	ix.rebuild(entities)
	return ix


## 决定格网尺度：轴格数由图元数推出（目标每格 TARGET_PER_CELL 个），
## 格网以覆盖区域中心展开，保证区域完全落在格网内。
func _plan(n: int, area: Rect2) -> void:
	var count := maxi(n, 1)
	var per_axis := clampi(int(sqrt(float(count) / float(TARGET_PER_CELL))),
		MIN_AXIS_CELLS, MAX_AXIS_CELLS)
	var span := maxf(maxf(area.size.x, area.size.y), 1.0) * 1.02
	_side = span / float(per_axis)
	var c := area.position + area.size * 0.5
	_origin = c - Vector2(_side, _side) * float(per_axis) * 0.5


func clear() -> void:
	_cells.clear()
	_oversized.clear()
	_count = 0
	_max_half = 0.0
	_expand = 1


## 重建索引。格网尺度已由 build() 定好，这里只重铺图元。
func rebuild(entities: Array[CadEntity]) -> void:
	clear()
	for e in entities:
		_place(e)


func insert(e: CadEntity) -> void:
	_place(e)


func _place(e: CadEntity) -> void:
	var bb: Rect2 = e.get_bbox()
	var half := maxf(bb.size.x, bb.size.y) * 0.5
	if half > _side * float(MAX_EXPAND):
		_oversized.append(e)
		_count += 1
		return
	if half > _max_half:
		_max_half = half
		_expand = maxi(1, int(ceilf(_max_half / _side)))
	var k := _cell_of(bb.get_center())
	var arr = _cells.get(k)
	if arr == null:
		_cells[k] = [e]
	else:
		(arr as Array).append(e)
	_count += 1


## 移除图元。按包围盒中心定位所在格 —— 与四叉树一样，这里假定图元的
## 包围盒没有变过；移动过的图元应重建索引。_expand 不随之缩小（宁大勿小，
## 只影响速度不影响正确性）。
func remove(e: CadEntity) -> bool:
	var i := _oversized.find(e)
	if i >= 0:
		_oversized.remove_at(i)
		_count -= 1
		return true
	var k := _cell_of(e.get_bbox().get_center())
	var arr = _cells.get(k)
	if arr == null:
		return false
	var a := arr as Array
	var j := a.find(e)
	if j < 0:
		return false
	a.remove_at(j)
	if a.is_empty():
		_cells.erase(k)
	_count -= 1
	return true


func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(int(floorf((p.x - _origin.x) / _side)),
		int(floorf((p.y - _origin.y) / _side)))


## 查询与矩形相交的图元。返回的是候选集（已按包围盒过滤），调用方仍需精确判定。
func query_rect(r: Rect2) -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	for e in _oversized:
		if e.get_bbox().intersects(r):
			out.append(e)
	var x0 := int(floorf((r.position.x - _origin.x) / _side)) - _expand
	var y0 := int(floorf((r.position.y - _origin.y) / _side)) - _expand
	var x1 := int(floorf((r.end.x - _origin.x) / _side)) + _expand
	var y1 := int(floorf((r.end.y - _origin.y) / _side)) + _expand
	# 查询范围比占用的格子还多时（例如缩到很小的窗选），直接扫占用格更划算
	if (x1 - x0 + 1) * (y1 - y0 + 1) > _cells.size():
		for arr in _cells.values():
			_collect(arr, r, out)
		return out
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var arr = _cells.get(Vector2i(cx, cy))
			if arr != null:
				_collect(arr, r, out)
	return out


func _collect(arr: Variant, r: Rect2, out: Array[CadEntity]) -> void:
	for e in (arr as Array):
		var ce := e as CadEntity
		if ce.get_bbox().intersects(r):
			out.append(ce)


## 查询包含给定点的图元候选
func query_point(p: Vector2, tol: float = 0.0) -> Array[CadEntity]:
	return query_rect(Rect2(p - Vector2(tol, tol), Vector2(tol, tol) * 2.0))


## 查询与给定线段相交的图元候选（栅栏选用）
func query_seg(a: Vector2, b: Vector2) -> Array[CadEntity]:
	return query_rect(Rect2(a, Vector2.ZERO).merge(Rect2(b, Vector2.ZERO)).grow(Tol.POINT))


## 遍历全部图元（不用于高频路径）。中心登记保证每个图元只出现一次。
func all() -> Array[CadEntity]:
	var out: Array[CadEntity] = []
	for arr in _cells.values():
		for e in (arr as Array):
			out.append(e as CadEntity)
	for e in _oversized:
		out.append(e)
	return out


## 统计，用于性能分析与测试
func stats() -> Dictionary:
	return {
		"nodes": _cells.size(),
		"items": _count,
		"max_depth": 1,
		"children": 0,
		"oversized": _oversized.size(),
		"side": _side,
		"expand": _expand,
	}
