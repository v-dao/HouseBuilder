extends SceneTree
## 记录：Godot Geometry2D 布尔运算的返回约定（实测结论）。
## 保留此脚本以便日后引擎升级后复核 —— 房间面积算法曾因误判此约定而出错。

func _initialize() -> void:
	var big := PackedVector2Array([
		Vector2(0, 0), Vector2(1000, 0), Vector2(1000, 1000), Vector2(0, 1000)])
	var small := PackedVector2Array([
		Vector2(400, 400), Vector2(600, 400), Vector2(600, 600), Vector2(400, 600)])
	print("大矩形减内部小矩形 -> 返回 %d 个多边形（外轮廓 + 洞混在同一数组）"
		% Geometry2D.clip_polygons(big, small).size())
	print("结论：只能靠几何包含关系区分外轮廓与洞，")
	print("      因此多步裁剪求房间区域不可靠，应改用平面剖分面追踪。")
	quit(0)
