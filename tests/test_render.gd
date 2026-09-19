class_name RenderTests
extends TestSuite
## 渲染回归测试。
##
## 存在的理由：渲染的问题往往"看起来对"，只有把渲染器当作普通对象调用、
## 检查它的内部统计，才能在无人看图时抓住回归。
##
## 这里专门覆盖几何缓存的**边界**：
## 哪些东西可以缓存、哪些必须每帧重算。划错边界会导致
## "只有缩放时文字才出现"这类只有肉眼能发现的缺陷。

var _root: Node = null


func run() -> void:
	suite = "渲染：几何缓存边界"
	_test_cache_keeps_aux()
	_test_cache_invalidation()
	_test_cache_equivalence()


## 需要一个真实（哪怕是 dummy）的渲染环境来承载 CanvasItem
func _make_canvas() -> Node2D:
	var n := Node2D.new()
	if _root != null:
		_root.add_child(n)
	return n


func _make_scene() -> Array:
	var doc := CadDocument.new()
	doc.add_entity(EntLine.make(Vector2(0, 0), Vector2(2000, 0)), false)
	doc.add_entity(EntLine.make(Vector2(0, 500), Vector2(2000, 500)), false)
	var t := EntText.make(Vector2(500, 200), "客厅", 300.0)
	doc.add_entity(t, false)
	doc.add_entity(EntPoint.make(Vector2(1000, 1000)), false)
	var ring := PackedVector2Array([
		Vector2(0, 1500), Vector2(800, 1500), Vector2(800, 2000), Vector2(0, 2000)])
	var h := EntHatch.make(ring, "实心")
	h.solid = true
	doc.add_entity(h, false)
	var view := ViewTransform.new()
	view.set_view_size(Vector2(800, 600))
	view.zoom_to_fit(Rect2(0, 0, 2000, 2000))
	return [doc, view]


## 核心回归：几何缓存命中时，文字/点/实心填充必须仍然被收集。
## 曾经的缺陷是把它们放进了"缓存命中就跳过"的图元遍历里，
## 于是只有缩放（缓存重建）时文字才出现。
func _test_cache_keeps_aux() -> void:
	var sc := _make_scene()
	var doc: CadDocument = sc[0]
	var view: ViewTransform = sc[1]
	var r := CadRenderer.new()
	var ci := _make_canvas()

	r.draw(doc, view, ci)
	var s1: Dictionary = r.stats.duplicate()
	ok(String(s1.get("cache", "")) == "build", "第一次应重建缓存")
	ok(int(s1.get("texts", 0)) > 0, "重建时应有文字，实际 %d" % int(s1.get("texts", 0)))
	ok(int(s1.get("points", 0)) > 0, "重建时应有点")
	ok(int(s1.get("solids", 0)) > 0, "重建时应有实心填充")

	# 同一视图再画一次：走缓存命中路径
	r.draw(doc, view, ci)
	var s2: Dictionary = r.stats
	ok(String(s2.get("cache", "")) == "hit", "第二次应命中缓存，实际 %s" % String(s2.get("cache", "")))
	ok(int(s2.get("texts", 0)) == int(s1.get("texts", 0)),
		"缓存命中时文字数必须不变：%d -> %d" % [int(s1.get("texts", 0)), int(s2.get("texts", 0))])
	ok(int(s2.get("points", 0)) == int(s1.get("points", 0)),
		"缓存命中时点数必须不变：%d -> %d" % [int(s1.get("points", 0)), int(s2.get("points", 0))])
	ok(int(s2.get("solids", 0)) == int(s1.get("solids", 0)),
		"缓存命中时实心填充数必须不变")
	ok(int(s2.get("segments", 0)) == int(s1.get("segments", 0)),
		"缓存命中时线段数必须不变：%d -> %d" % [int(s1.get("segments", 0)), int(s2.get("segments", 0))])
	ci.queue_free()


## 缓存必须在该失效的时候失效：内容变了、图层可见性变了、缩放变了
func _test_cache_invalidation() -> void:
	var sc := _make_scene()
	var doc: CadDocument = sc[0]
	var view: ViewTransform = sc[1]
	var r := CadRenderer.new()
	var ci := _make_canvas()

	r.draw(doc, view, ci)
	var seg0 := int(r.stats.get("segments", 0))

	# 1) 文档内容变化
	doc.add_entity(EntLine.make(Vector2(0, 800), Vector2(2000, 800)), false)
	r.draw(doc, view, ci)
	ok(String(r.stats.get("cache", "")) == "build", "内容变化后应重建")
	ok(int(r.stats.get("segments", 0)) > seg0,
		"新增图元后线段数应增加：%d -> %d" % [seg0, int(r.stats.get("segments", 0))])

	# 2) 图层可见性变化 —— 这类改动不经 add/remove，必须由界面显式 bump
	var after_add := int(r.stats.get("segments", 0))
	var l := doc.get_layer("0")
	l.visible = false
	doc.bump()
	r.draw(doc, view, ci)
	ok(String(r.stats.get("cache", "")) == "build", "图层可见性变化后应重建")
	ok(int(r.stats.get("segments", 0)) == 0,
		"隐藏图层后不应再画线段，实际 %d" % int(r.stats.get("segments", 0)))
	ok(int(r.stats.get("texts", 0)) == 0, "隐藏图层后不应再画文字")
	l.visible = true
	doc.bump()
	r.draw(doc, view, ci)
	ok(int(r.stats.get("segments", 0)) == after_add, "恢复可见后线段数应回到原值")

	# 3) 缩放变化（跨档位）应重建。注意缩放会改变视口剔除范围，
	#    因此线段数本来就会变 —— 这里只断言确实重建了。
	view.zoom *= 1.5
	r.draw(doc, view, ci)
	ok(String(r.stats.get("cache", "")) == "build", "缩放跨档位后应重建")

	# 4) 视图平移不跨档位，应命中缓存。
	#    缓存键含缩放档位但不含平移，所以平移不会重建 ——
	#    代价是不再按视口重新剔除（已记入性能文档的取舍）。
	var seg_after_zoom := int(r.stats.get("segments", 0))
	view.center += Vector2(50, 50)
	r.draw(doc, view, ci)
	ok(String(r.stats.get("cache", "")) == "hit",
		"小幅平移不应导致重建，实际 %s" % String(r.stats.get("cache", "")))
	ok(int(r.stats.get("segments", 0)) == seg_after_zoom, "平移后线段数不变")
	ci.queue_free()


## 缓存结果必须与重建结果等价：几何点不能因走缓存而丢失或错位
func _test_cache_equivalence() -> void:
	var sc := _make_scene()
	var doc: CadDocument = sc[0]
	var view: ViewTransform = sc[1]
	# 一次性加很多图元，让点串有可比对的规模
	for i in range(200):
		doc.add_entity(EntLine.make(Vector2(i * 10, -500), Vector2(i * 10, -300)), false)

	var r1 := CadRenderer.new()
	var ci1 := _make_canvas()
	r1.draw(doc, view, ci1)
	var seg1 := int(r1.stats.get("segments", 0))
	var drawn1 := int(r1.stats.get("drawn", 0))

	# 换一个渲染器实例（必然重建）与同一视图，比线段数
	var r2 := CadRenderer.new()
	var ci2 := _make_canvas()
	r2.draw(doc, view, ci2)
	ok(int(r2.stats.get("segments", 0)) == seg1,
		"两次构建的线段数应一致：%d vs %d" % [seg1, int(r2.stats.get("segments", 0))])
	ok(int(r2.stats.get("drawn", 0)) == drawn1, "两次构建的可见图元数应一致")
	ok(int(r2.stats.get("buckets", 0)) == int(r1.stats.get("buckets", 0)), "分桶数应一致")

	# 缓存命中后再重建，结果仍应自洽（防止缓存污染了后续构建）。
	# 这里回到原缩放重建，才能与首次的结果直接对比 ——
	# 换缩放会改变剔除范围，可见图元数本就不同。
	r1.draw(doc, view, ci1)
	ok(String(r1.stats.get("cache", "")) == "hit", "应命中缓存")
	var z := view.zoom
	view.zoom *= 2.0
	r1.draw(doc, view, ci1)
	ok(String(r1.stats.get("cache", "")) == "build", "缩放后应重建")
	ok(int(r1.stats.get("drawn", 0)) > 0, "缩放后仍应画出图元")
	view.zoom = z
	r1.draw(doc, view, ci1)
	ok(String(r1.stats.get("cache", "")) == "build", "回到原缩放应再次重建")
	ok(int(r1.stats.get("drawn", 0)) == drawn1,
		"回到原缩放后可见图元数应与首次一致：%d vs %d" % [drawn1, int(r1.stats.get("drawn", 0))])
	ok(int(r1.stats.get("segments", 0)) == seg1, "回到原缩放后线段数应与首次一致")
	ci1.queue_free()
	ci2.queue_free()
