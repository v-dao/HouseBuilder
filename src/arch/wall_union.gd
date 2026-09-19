class_name WallUnion
extends RefCounted
## 墙体并集轮廓。
##
## 问题：每堵墙各自生成双线轮廓时，两墙相接处会露出对方的端边与内线，
## 看上去像"几条独立的墙碰在一起"，而不是一栋建筑。
##
## 做法：把所有墙体的实心段多边形求并集，只画并集的外轮廓。
## 并集天然包含洞口处的垛口侧壁，因此门窗洞口的画法同时也是正确的。
##
## 性能：布尔运算不便宜，故按文档 revision 缓存；
## 文档每次变更 revision 自增，缓存自动失效。

static var _cache_revision: int = -1
static var _cache_doc_id: int = 0
static var _cache: Array = []


## 返回墙体并集后的轮廓多边形列表。
static func outline(doc: CadDocument) -> Array:
	if doc == null:
		return []
	var did := doc.get_instance_id()
	if doc.revision == _cache_revision and did == _cache_doc_id:
		return _cache
	var polys: Array = []
	for e in doc.entities:
		if not (e is EntWall):
			continue
		var w := e as EntWall
		if not w.visible or not doc.is_layer_visible(w.layer):
			continue
		for p in w.solid_polygons():
			polys.append(p)
	var res := union_all(polys)
	_cache = res
	_cache_revision = doc.revision
	_cache_doc_id = did
	return res


## 合并一组多边形。逐个与已有结果合并，允许结果分裂成多块。
static func union_all(polys: Array) -> Array:
	var acc: Array = []
	for poly in polys:
		if (poly as PackedVector2Array).size() < 3:
			continue
		var pending: Array = [poly]
		for i in range(acc.size()):
			if pending.is_empty():
				break
			var existing: PackedVector2Array = acc[i]
			if existing.size() < 3:
				continue
			var next_pending: Array = []
			for p in pending:
				var res: Array = Geometry2D.merge_polygons(existing, p)
				if res.is_empty():
					next_pending.append(p)
					continue
				# merge_polygons 的约定：第一块是并集外轮廓，其余是洞或分离块
				existing = res[0]
				for k in range(1, res.size()):
					next_pending.append(res[k])
			acc[i] = existing
			pending = next_pending
		for p in pending:
			acc.append(p)
	# 清理退化结果
	var out: Array = []
	for a in acc:
		if (a as PackedVector2Array).size() >= 3:
			out.append(a)
	return out


## 供测试与调试：清空缓存
static func clear_cache() -> void:
	_cache_revision = -1
	_cache = []
