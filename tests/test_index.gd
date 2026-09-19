class_name IndexTests
extends TestSuite
## 空间索引与"合并重建"的回归测试。
##
## 存在的理由：这次改造修的是一个**只有规模上去了才会痛**的缺陷 ——
## 批量操作会连发 N 次文档变更，原先每次变更都重建一遍索引，
## 十万图元下删 5 个图元实测卡 3.235 秒。功能测试全绿也发现不了它，
## 因为小图上重建只要几百微秒。
##
## 所以这里断言两件事：
##   1. N 次变更只重建一次（用重建计数直接观察，不靠计时）
##   2. 惰性重建不会让索引变旧（任何读取路径拿到的都是最新的）

var _root: Node = null


func run() -> void:
	suite = "空间索引：合并重建与新鲜度"
	_test_flat_index_basics()
	_test_expansion_finds_offscreen_body()
	_test_oversized_still_queryable()
	_test_batch_changes_rebuild_once()
	_test_index_never_stale()
	_test_ctx_index_is_fresh()


func _make_doc() -> CadDocument:
	var doc := CadDocument.new()
	for i in range(40):
		var x := float(i) * 300.0
		doc.add_entity(EntLine.make(Vector2(x, 0.0), Vector2(x, 200.0)), false)
	return doc


func _make_viewport(doc: CadDocument) -> CadViewport:
	var vp := CadViewport.new()
	vp.size = Vector2(800, 600)
	if _root != null:
		_root.add_child(vp)
	vp.setup(doc)
	return vp


## 扁平网格索引的基本正确性
func _test_flat_index_basics() -> void:
	var doc := _make_doc()
	var ix := SpatialIndex.build(doc.entities, doc.get_bbox())
	ok(int(ix.stats()["items"]) == doc.entity_count(),
		"索引内图元数应等于文档图元数：%d vs %d" % [int(ix.stats()["items"]), doc.entity_count()])
	ok(int(ix.stats()["nodes"]) >= 1, "应至少有一个格子")

	# 每条线段的端点都应能被点查命中
	var miss := 0
	for e in doc.entities:
		var ln := e as EntLine
		if ix.query_point(ln.p0, 1.0).is_empty():
			miss += 1
	ok(miss == 0, "每个图元的起点都应能被查到，落空 %d 个" % miss)

	# 点查结果必须都是真的覆盖该点的图元（不能有无关图元混进来）
	var p := Vector2(300.0, 100.0)
	var hit := ix.query_point(p, 1.0)
	ok(hit.size() == 1, "该点应只命中一条线，实际 %d" % hit.size())
	if hit.size() == 1:
		ok(hit[0] == doc.entities[1], "命中的应是第二条线")

	# all() 不许有重复（中心登记的关键好处）
	ok(ix.all().size() == doc.entity_count(), "all() 不应重复登记图元")
	ok(ix.query_rect(Rect2(-10, -10, 20000, 20000)).size() == doc.entity_count(),
		"覆盖全图的查询应返回全部图元")


## 自适应扩张是正确性的关键：图元只登记在中心所在格，
## 查询若不按最长半轴外扩就会漏掉"身体伸到邻格"的图元。
func _test_expansion_finds_offscreen_body() -> void:
	# 范围 2000mm -> 格边长约 255mm；线段长 600mm（半轴 300mm）-> 外扩 2 格
	var area := Rect2(0.0, 0.0, 2000.0, 2000.0)
	var ln := EntLine.make(Vector2(900.0, 1000.0), Vector2(1500.0, 1000.0))
	var ix := SpatialIndex.build([ln] as Array[CadEntity], area)
	var st := ix.stats()
	ok(int(st["expand"]) >= 2, "按最长半轴应外扩至少 2 格，实际 %d" % int(st["expand"]))
	ok(int(st["oversized"]) == 0, "这个尺寸不该进超规格清单")

	# 线段的**远端**（离中心所在格很远）也必须查得到
	ok(ix.query_point(ln.p1, 1.0).size() == 1, "线段远端必须能被点查命中")
	ok(ix.query_rect(Rect2(1490.0, 990.0, 20.0, 20.0)).size() == 1,
		"线段远端的小窗选也必须命中")


## 超规格清单是安全阀：调用方传的范围比内容范围小得多时才会用到。
## 一旦用上，图元必须仍然查得到 —— 这是最容易写漏的分支。
func _test_oversized_still_queryable() -> void:
	var entities: Array[CadEntity] = []
	for i in range(20):
		entities.append(EntLine.make(Vector2(0.0, float(i) * 10.0),
			Vector2(500000.0, float(i) * 10.0)))       # 500m 长线
	# 故意只给一个 2000mm 的小范围：格边长约 255mm，外扩上限 1020mm，
	# 长线半轴 250000mm 远超上限 -> 只能进超规格清单
	var ix := SpatialIndex.build(entities, Rect2(0.0, 0.0, 2000.0, 2000.0))
	ok(int(ix.stats()["oversized"]) == 20,
		"范围远小于内容时长图元应进超规格清单，实际 %d" % int(ix.stats()["oversized"]))
	ok(int(ix.stats()["items"]) == 20, "超规格图元也要计入总数")
	# 线间距 10mm、点查容差 1mm，所以该点只应命中 y=50 那一条
	ok(ix.query_point(Vector2(250000.0, 50.0), 1.0).size() == 1,
		"长线远端中点应被命中")
	ok(ix.query_point(Vector2(250000.0, 0.0), 1.0).size() == 1, "y=0 那条也应被命中")
	ok(ix.remove(entities[0]), "超规格图元应能被移除")
	ok(int(ix.stats()["items"]) == 19, "移除后计数应减一")
	ok(ix.query_point(Vector2(250000.0, 0.0), 1.0).is_empty(), "被移除的那条不该再命中")
	ok(ix.query_point(Vector2(250000.0, 50.0), 1.0).size() == 1, "其它条不受影响")


## 核心回归：N 次文档变更只允许重建一次索引
func _test_batch_changes_rebuild_once() -> void:
	var doc := _make_doc()
	var vp := _make_viewport(doc)
	ok(vp.index_builds == 0, "setup 之后还不该建索引（惰性），实际 %d 次" % vp.index_builds)

	# 第一次取用：建一次
	vp.spatial_index()
	ok(vp.index_builds == 1, "首次取用应建一次，实际 %d 次" % vp.index_builds)

	# 连着取用：不该重复建
	vp.spatial_index()
	vp.spatial_index()
	ok(vp.index_builds == 1, "重复取用不该重复建，实际 %d 次" % vp.index_builds)

	# 一次批量变更：删 5 个图元。这是缺陷的原始场景。
	var before := vp.index_builds
	for i in range(5):
		doc.remove_entity(doc.entities[0], false)
	ok(vp.index_builds == before,
		"变更过程中不该重建（还没人取索引），实际多建了 %d 次" % (vp.index_builds - before))

	# 变更后第一次取用：建一次，且只建一次
	vp.spatial_index()
	ok(vp.index_builds == before + 1,
		"5 次变更应合并成 1 次重建，实际多建了 %d 次" % (vp.index_builds - before))
	vp.spatial_index()
	ok(vp.index_builds == before + 1, "紧接着再取用不该再建")

	# 再删 100 个（超过原文档规模，用新增图元补齐）
	for i in range(100):
		doc.add_entity(EntLine.make(Vector2(float(i) * 7.0, 900.0), Vector2(float(i) * 7.0, 1100.0)), false)
	var before2 := vp.index_builds
	vp.spatial_index()
	vp.spatial_index()
	ok(vp.index_builds == before2 + 1,
		"100 次变更同样只应重建一次，实际多建了 %d 次" % (vp.index_builds - before2))
	vp.queue_free()


## 惰性重建不能变旧：变更后任何读取路径都该拿到包含新图元的索引
func _test_index_never_stale() -> void:
	var doc := _make_doc()
	var vp := _make_viewport(doc)
	vp.spatial_index()

	var fresh := EntLine.make(Vector2(10000.0, 10000.0), Vector2(10200.0, 10000.0))
	doc.begin_transaction("测试")
	doc.add_entity(fresh)
	doc.commit_transaction()
	var hit := vp.spatial_index().query_point(fresh.p0, 1.0)
	ok(hit.size() == 1 and hit[0] == fresh, "新增图元必须立刻可被索引查到")

	# 删除后也不该再查到
	doc.begin_transaction("测试")
	doc.remove_entity(fresh)
	doc.commit_transaction()
	ok(vp.spatial_index().query_point(fresh.p0, 1.0).is_empty(),
		"删除后的图元不该再被索引查到")

	# 撤销/重做路径同样（它们原先显式重建，现在交给惰性机制）
	vp.undo()
	ok(not vp.spatial_index().query_point(fresh.p0, 1.0).is_empty(),
		"撤销删除后图元应重新可查")
	vp.redo()
	ok(vp.spatial_index().query_point(fresh.p0, 1.0).is_empty(),
		"重做删除后图元应再次不可查")
	vp.queue_free()


## 命令通过 ctx.index 取索引，也必须拿到最新的一份
func _test_ctx_index_is_fresh() -> void:
	var doc := _make_doc()
	var vp := _make_viewport(doc)
	vp.spatial_index()
	vp.index_builds = 0

	var extra := EntLine.make(Vector2(-5000.0, -5000.0), Vector2(-4800.0, -5000.0))
	doc.add_entity(extra, false)
	# 命令侧的读取路径：ctx.index 是计算属性，会向视口索取
	var got := vp.ctx.index.query_point(extra.p0, 1.0)
	ok(got.size() == 1 and got[0] == extra, "命令通过 ctx.index 应拿到包含新图元的索引")
	ok(vp.index_builds == 1, "这次读取应只触发一次重建，实际 %d 次" % vp.index_builds)
	vp.queue_free()
