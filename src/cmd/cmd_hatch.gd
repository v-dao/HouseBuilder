class_name CmdHatch
extends RefCounted
## 图案填充命令。
##
## 边界识别两条路径（与 AutoCAD 的用法一致）：
##   1. 点取内部点 —— 自动找出包围该点的**最小的**闭合图元
##   2. 选择对象   —— 把若干首尾相接的图元串成一个闭合环
##
## 取"最小"闭合图元是有意的：点在一堵墙里时，
## 外圈的整层轮廓也包含该点，但用户要的是那堵墙。


class HatchCmd extends CadCommand:
	enum { S_PATTERN, S_PICK, S_SELECT }
	var _state := S_PATTERN
	var _pattern := "钢筋混凝土"
	var _solid := false
	var _selected: Array[CadEntity] = []

	func cmd_name() -> String:
		return "HATCH"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["h", "bh", "填充"])

	func help_text() -> String:
		return "图案填充：输入图例名（或 S 表示实心）-> 点取内部点，或输入 O 选择边界对象"

	func is_selecting() -> bool:
		return _state == S_SELECT

	func start(_args: Dictionary) -> void:
		ctx.doc.begin_transaction("图案填充")
		_state = S_PATTERN
		_selected.clear()
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_PATTERN:
				return "HATCH 输入图例名 <钢筋混凝土>（S=实心，L 列出可用图例）:"
			S_PICK:
				return "HATCH 点取内部点，或输入 O 选择边界对象 [%s]:" % _pattern
			S_SELECT:
				return "HATCH 选择边界对象（回车确认，已选 %d 个）:" % _selected.size()
		return ""

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_PATTERN:
				var up := t.to_upper()
				if up == "L":
					ctx.set_status("可用图例：" + ", ".join(GbHatch.pattern_names()))
					return false
				if up == "S":
					_solid = true
					_pattern = "实心"
				elif t != "":
					if not GbHatch.library().has(t):
						# 允许模糊匹配，找不到就明确报出来
						var hit := _fuzzy(t)
						if hit == "":
							ctx.set_status("没有图例「%s」，输入 L 可列出全部" % t)
							return false
						_pattern = hit
					else:
						_pattern = t
				_state = S_PICK
				ctx.set_status(prompt())
				return false
			S_PICK:
				if t.to_upper() == "O":
					_state = S_SELECT
					ctx.set_status(prompt())
					return false
			S_SELECT:
				# 选择阶段由视口处理，命令行输入忽略
				return false
		return false

	func _fuzzy(t: String) -> String:
		for name in GbHatch.pattern_names():
			if name.contains(t) or t.contains(name):
				return name
		return ""

	func on_point(p: Vector2) -> bool:
		match _state:
			S_PATTERN:
				return false
			S_PICK:
				var b := _find_boundary_at(p)
				if b.is_empty():
					ctx.set_status("该点周围没有闭合边界，可用 O 手动选择边界对象")
					return false
				_emit(b)
				_finish()
				return true
			S_SELECT:
				return false
		return false

	func on_enter() -> bool:
		if _state == S_SELECT:
			if _selected.is_empty():
				ctx.set_status("未选择边界对象")
				_abort()
				return true
			var b := _chain_to_loop(_selected)
			if b.is_empty():
				ctx.set_status("所选对象无法串成闭合边界")
				_abort()
				return true
			_emit(b)
			_finish()
			return true
		if _state == S_PATTERN:
			_state = S_PICK
			ctx.set_status(prompt())
			return false
		_abort()
		return true

	func _emit(b: PackedVector2Array) -> void:
		var h := EntHatch.make(b, _pattern)
		h.solid = _solid
		h.layer = ctx.doc.current_layer
		h.aci = ctx.doc.current_aci
		# 图案相位以边界包围盒左下角为基准，使相邻填充的图案能对齐
		h.origin = GbHatch._bbox(b).position
		ctx.doc.add_entity(h)

	func _finish() -> void:
		ctx.doc.commit_transaction()
		ctx.set_status("")

	func _abort() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	func cancel() -> void:
		_abort()

	func on_mouse_move(_p: Vector2) -> void:
		ctx.request_redraw()

	## 找出包围给定点的最小闭合图元
	func _find_boundary_at(p: Vector2) -> PackedVector2Array:
		var tol := ctx.view.tolerance_for_pixels(1.0)
		var cands: Array[CadEntity] = []
		if ctx.index != null:
			cands = ctx.index.query_point(p, tol)
		else:
			cands = ctx.doc.entities
		var best: PackedVector2Array = PackedVector2Array()
		var best_area := INF
		for e in cands:
			if not e.visible:
				continue
			var poly := _boundary_of(e)
			if poly.size() < 3:
				continue
			if not GbHatch.point_in_polygon(p, poly):
				continue
			var a := _area(poly)
			if a > 0.0 and a < best_area:
				best_area = a
				best = poly
		return best

	## 取图元的闭合轮廓（圆、闭合多段线、首尾重合的多段线）
	func _boundary_of(e: CadEntity) -> PackedVector2Array:
		for c in e.get_curves():
			match c.kind():
				GeoCurve.Kind.ARC:
					var a := c as GeoArc
					if a.is_full_circle():
						var pts := a.tessellate(maxf(a.radius * 0.002, 0.05))
						# 去掉与首点重合的末点，内部统一按"不重复首点"处理
						while pts.size() > 1 and pts[0].distance_to(pts[pts.size() - 1]) <= Tol.POINT:
							pts.remove_at(pts.size() - 1)
						return pts
				GeoCurve.Kind.POLY:
					var p := c as GeoPoly
					var pts2 := p.points.duplicate()
					var closed := p.closed
					if not closed and pts2.size() > 2 \
							and pts2[0].distance_to(pts2[pts2.size() - 1]) <= Tol.POINT:
						closed = true
					while pts2.size() > 1 and pts2[0].distance_to(pts2[pts2.size() - 1]) <= Tol.POINT:
						pts2.remove_at(pts2.size() - 1)
					if closed and pts2.size() >= 3:
						return pts2
				_:
					pass
		return PackedVector2Array()

	## 多边形面积（鞋带公式，取绝对值）
	static func _area(poly: PackedVector2Array) -> float:
		var s := 0.0
		var n := poly.size()
		for i in range(n):
			var a := poly[i]
			var b := poly[(i + 1) % n]
			s += a.x * b.y - b.x * a.y
		return absf(s) * 0.5

	## 把若干图元串成闭合环。逐段找首尾相接的下一条，允许反向。
	func _chain_to_loop(list: Array) -> PackedVector2Array:
		var curves: Array[GeoCurve] = []
		for e in list:
			for c in CurveOps.decompose_all(e):
				curves.append(c)
		if curves.is_empty():
			return PackedVector2Array()

		var used := []
		used.resize(curves.size())
		for i in range(used.size()):
			used[i] = false

		var chain := CurveOps.decompose(curves[0])[0].tessellate(0.1)
		used[0] = true
		var remaining := curves.size() - 1
		var guard := 0
		while remaining > 0 and guard < curves.size() * 2:
			guard += 1
			var tail := chain[chain.size() - 1]
			var advanced := false
			for i in range(curves.size()):
				if used[i]:
					continue
				var pts := curves[i].tessellate(0.1)
				if pts.size() < 2:
					used[i] = true
					remaining -= 1
					continue
				if pts[0].distance_to(tail) <= Tol.POINT:
					for k in range(1, pts.size()):
						chain.append(pts[k])
					used[i] = true
					remaining -= 1
					advanced = true
					break
				if pts[pts.size() - 1].distance_to(tail) <= Tol.POINT:
					for k in range(pts.size() - 2, -1, -1):
						chain.append(pts[k])
					used[i] = true
					remaining -= 1
					advanced = true
					break
			if not advanced:
				break
		# 检查闭合
		if chain.size() < 3 or chain[0].distance_to(chain[chain.size() - 1]) > Tol.POINT:
			return PackedVector2Array()
		chain.remove_at(chain.size() - 1)
		return chain

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_PICK:
			return
		# 预览：高亮将要作为边界的闭合图元
		var b := _find_boundary_at(p)
		if b.size() < 3:
			return
		var out := PackedVector2Array()
		for q in b:
			out.append(view.to_screen(q))
		out.append(view.to_screen(b[0]))
		ci.draw_polyline(out, Color(0.6, 0.9, 1.0, 0.9), 1.5, true)
