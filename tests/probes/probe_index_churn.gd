extends SceneTree
## 端到端验证"合并重建"：十万图元下批量删除，索引重建几次、卡多久。
##
## 原始缺陷（本次修的就是它）：_bump() 每次单点改动都 emit changed，
## 视口每次都整树重建 —— 删 5 个图元触发 5 次重建，实测卡 3235ms。
## 这一版应当：变更过程一次都不重建（没人取索引），事后第一次取用时只建一次。

const N := 100000
const N_REMOVE := 5


func _initialize() -> void:
	var doc := CadDocument.new()
	var t0 := Time.get_ticks_msec()
	for i in range(N):
		var x := float(i % 500) * 200.0
		var y := float(i / 500) * 200.0
		doc.add_entity(EntLine.make(Vector2(x, y), Vector2(x + 150.0, y + 120.0)), false)
	print("建文档 %d 图元：%d ms" % [N, Time.get_ticks_msec() - t0])

	var vp := CadViewport.new()
	vp.size = Vector2(800, 600)
	root.add_child(vp)
	vp.setup(doc)

	# 先取一次，建立基线（惰性：不取就不建）
	vp.spatial_index()
	print("首次取用建索引：%d 次，耗时基线已建立" % vp.index_builds)

	# 批量删除：这一步在修复前会触发 N_REMOVE 次重建
	var before := vp.index_builds
	var victims: Array[CadEntity] = []
	for i in range(N_REMOVE):
		victims.append(doc.entities[i * 7])
	var t2 := Time.get_ticks_msec()
	for e in victims:
		doc.remove_entity(e, false)
	var dt_mutate := Time.get_ticks_msec() - t2
	print("删除 %d 个图元耗时：%d ms，期间重建 %d 次" % [
		N_REMOVE, dt_mutate, vp.index_builds - before])

	# 事后第一次取用：应只重建一次
	var t3 := Time.get_ticks_msec()
	var ix := vp.spatial_index()
	var dt_build := Time.get_ticks_msec() - t3
	print("事后首次取用：重建 %d 次，耗时 %d ms（索引内 %d 个图元）" % [
		vp.index_builds - before, dt_build, int(ix.stats()["items"])])

	# 再取用若干次，不该再重建
	for i in range(5):
		vp.spatial_index()
	print("再取用 5 次后累计重建次数：%d 次" % (vp.index_builds - before))
	print("")
	var total := dt_mutate + dt_build
	if vp.index_builds - before == 1:
		print("** 通过：%d 次变更合并成 1 次重建，端到端 %d ms（修复前为 5 次重建、3235 ms）" % [
			N_REMOVE, total])
	else:
		print("** 失败：%d 次变更触发了 %d 次重建" % [N_REMOVE, vp.index_builds - before])
	quit(0)
