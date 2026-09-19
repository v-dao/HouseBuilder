class_name CmdArch
extends RefCounted
## 建筑专用命令：轴网、墙体、门窗、房间、楼梯、门窗表。
##
## 这一组命令把"画线"提升为"建构件"：轴网知道自己的轴距与编号、
## 墙体知道自己的厚度与洞口、房间知道自己的边界与面积。
## 后续的平法配筋、排砖、工程量统计都依赖这些语义数据。


class ArchBase extends CadCommand:
	func _begin(label: String) -> void:
		ctx.doc.begin_transaction(label)

	func _finish() -> void:
		ctx.doc.commit_transaction()
		ctx.set_status("")

	func _abort() -> void:
		ctx.doc.rollback_transaction()
		ctx.set_status("")

	func on_mouse_move(_p: Vector2) -> void:
		ctx.request_redraw()

	func _preview_entity(ci: CanvasItem, view: ViewTransform, e: CadEntity) -> void:
		var col := Color(0.6, 0.9, 1.0, 0.85)
		for c in e.get_curves():
			var pts := PackedVector2Array()
			for q in c.tessellate(view.sagitta_for_pixels(0.5)):
				pts.append(view.to_screen(q))
			if pts.size() >= 2:
				ci.draw_polyline(pts, col, 1.0, true)


# ===========================================================================
# 轴网
# ===========================================================================

class AxisGridCmd extends ArchBase:
	enum { S_X, S_Y, S_ORIGIN }
	var _state := S_X
	var _x_spans: Array[float] = []
	var _y_spans: Array[float] = []
	var _xs: Array[float] = []
	var _ys: Array[float] = []

	func cmd_name() -> String:
		return "AXISGRID"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["ag", "轴网"])

	func help_text() -> String:
		return "轴网：输入横向轴距 -> 纵向轴距 -> 点取左下角。支持 3*3600 这种写法"

	func start(_args: Dictionary) -> void:
		_begin("生成轴网")
		_state = S_X
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_X:
				return "AXISGRID 输入横向轴距（空格分隔，如 3600 4200 3600，或 3*3600）:"
			S_Y:
				return "AXISGRID 输入纵向轴距（空格分隔）:"
			S_ORIGIN:
				return "AXISGRID 点取轴网左下角（第 1 轴与 A 轴交点）:"
		return ""

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		match _state:
			S_X:
				var spans := AxisGrid.parse_spans(t)
				if spans.is_empty():
					ctx.set_status("轴距格式不对，例如：3600 4200 3600 或 3*3600")
					return false
				_x_spans = spans
				_state = S_Y
			S_Y:
				var spans2 := AxisGrid.parse_spans(t)
				if spans2.is_empty():
					ctx.set_status("轴距格式不对")
					return false
				_y_spans = spans2
				_xs = AxisGrid.positions_from_spans(_x_spans)
				_ys = AxisGrid.positions_from_spans(_y_spans)
				_state = S_ORIGIN
		ctx.set_status(prompt())
		return false

	func on_point(p: Vector2) -> bool:
		if _state != S_ORIGIN:
			return false
		AxisGrid.build(ctx.doc, _xs, _ys, p)
		_finish()
		var letters := AxisGrid.axis_letters(_ys.size())
		ctx.set_status("轴网已生成：%d × %d 轴（纵向编号 %s）" % [
			_xs.size(), _ys.size(), ", ".join(letters)])
		return true

	func on_enter() -> bool:
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_ORIGIN or _xs.is_empty():
			return
		# 预览轴网范围
		var a := view.to_screen(p + Vector2(float(_xs[0]), float(_ys[0])))
		var b := view.to_screen(p + Vector2(float(_xs[_xs.size() - 1]), float(_ys[_ys.size() - 1])))
		ci.draw_rect(Rect2(a, Vector2.ZERO).merge(Rect2(b, Vector2.ZERO)),
			Color(0.6, 0.9, 1.0, 0.6), false, 1.0)


# ===========================================================================
# 墙体
# ===========================================================================

class WallCmd extends ArchBase:
	enum { S_THICK, S_PTS }
	var _state := S_THICK
	var _thick := 240.0
	var _pts := PackedVector2Array()
	var _closed := false

	func cmd_name() -> String:
		return "WALL"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["w", "墙", "双线墙"])

	func help_text() -> String:
		return "墙体：输入墙厚（120/180/240/370）-> 依次点取中心线各点 -> C 闭合 / 回车结束"

	func start(_args: Dictionary) -> void:
		_begin("画墙体")
		_state = S_THICK
		_pts = PackedVector2Array()
		_closed = false
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == S_THICK:
			return "WALL 输入墙厚 <240>:"
		if _pts.is_empty():
			return "WALL 指定墙体中心线起点:"
		return "WALL 指定下一点 [闭合(C)/放弃(U)]（回车结束）:"

	func on_text(s: String) -> bool:
		var t := s.strip_edges()
		if _state == S_THICK:
			if t != "":
				var v := t.to_float()
				if v <= 0.0:
					ctx.set_status("墙厚必须大于 0")
					return false
				_thick = v
			_state = S_PTS
			ctx.set_status(prompt())
			return false
		var up := t.to_upper()
		if up == "C" and _pts.size() >= 3:
			_closed = true
			_emit()
			return true
		if up == "U" and _pts.size() > 0:
			_pts.remove_at(_pts.size() - 1)
			ctx.request_redraw()
			return false
		return false

	func on_point(p: Vector2) -> bool:
		if _state == S_THICK:
			_state = S_PTS
		_pts.append(p)
		ctx.set_status(prompt())
		ctx.request_redraw()
		return false

	func on_enter() -> bool:
		if _state == S_THICK:
			_state = S_PTS
			ctx.set_status(prompt())
			return false
		if _pts.size() >= 2:
			_emit()
			return true
		_abort()
		return true

	func _emit() -> void:
		var w := EntWall.make(_pts, _thick, _closed)
		w.layer = "墙体"
		w.aci = 256
		ctx.doc.add_entity(w)
		_finish()
		ctx.set_status("墙体已生成，长 %.0fmm，厚 %.0fmm" % [w._centerline_length(), _thick])

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _pts.is_empty():
			return
		var scr := PackedVector2Array()
		for q in _pts:
			scr.append(view.to_screen(q))
		scr.append(view.to_screen(p))
		if scr.size() >= 2:
			# 沿中心线两侧各画一条偏移预览线，直观显示墙厚
			var half := _thick * 0.5 * view.zoom
			ci.draw_polyline(scr, Color(0.6, 0.9, 1.0, 0.9), half * 2.0, false)


# ===========================================================================
# 门窗插入
# ===========================================================================

class OpeningCmd extends ArchBase:
	enum { S_BLOCK, S_WALL, S_POS }
	var _state := S_BLOCK
	var _block := ""
	var _wall: EntWall = null
	var _is_window := false

	func _init(is_window := false) -> void:
		_is_window = is_window

	func cmd_name() -> String:
		return "WINDOW" if _is_window else "DOOR"

	func aliases() -> PackedStringArray:
		if _is_window:
			return PackedStringArray(["win", "窗"])
		return PackedStringArray(["dr", "门"])

	func help_text() -> String:
		if _is_window:
			return "插入窗：输入窗编号（如 C1515，L 列出）-> 点取墙体 -> 点取洞口位置"
		return "插入门：输入门编号（如 M0921，L 列出）-> 点取墙体 -> 点取洞口位置"

	func _default_block() -> String:
		return "C1515" if _is_window else "M0921"

	func start(_args: Dictionary) -> void:
		_begin(cmd_name())
		_state = S_BLOCK
		_block = _default_block()
		_wall = null
		ctx.set_status(prompt())

	func prompt() -> String:
		match _state:
			S_BLOCK:
				return "%s 输入编号 <%s>（L 列出可用）:" % [cmd_name(), _default_block()]
			S_WALL:
				return "%s 点取要开洞的墙体:" % cmd_name()
			S_POS:
				return "%s 点取洞口位置（沿墙）:" % cmd_name()
		return ""

	## 从块名解析洞口宽度：编号规则 M/C + 宽(2位) + 高(2位)，单位 100mm
	static func width_from_code(code: String) -> float:
		var c := code.strip_edges().to_upper()
		if c.length() < 5:
			return 0.0
		return float(c.substr(1, 2).to_int()) * 100.0

	func on_text(s: String) -> bool:
		if _state != S_BLOCK:
			return false
		var t := s.strip_edges()
		if t.to_upper() == "L":
			ctx.set_status("可用门窗块：" + ", ".join(_candidates()))
			return false
		if t != "":
			var hit := _resolve(t)
			if hit == "":
				ctx.set_status("找不到编号「%s」，输入 L 可列出全部" % t)
				return false
			_block = hit
		_state = S_WALL
		ctx.set_status(prompt())
		return false

	func _candidates() -> Array[String]:
		var out: Array[String] = []
		for n in GbBlocks.block_names():
			var s := String(n)
			if _is_window and s.begins_with("C"):
				out.append(s)
			elif not _is_window and s.begins_with("M"):
				out.append(s)
		return out

	func _resolve(t: String) -> String:
		var up := t.to_upper()
		for n in _candidates():
			if String(n).to_upper() == up:
				return String(n)
		for n in _candidates():
			if String(n).to_upper().begins_with(up):
				return String(n)
		return ""

	func on_point(p: Vector2) -> bool:
		match _state:
			S_WALL:
				var tol := ctx.view.tolerance_for_pixels(10.0)
				var e := CadSelection.pick(ctx.doc, ctx.index, p, tol)
				if e == null or not (e is EntWall):
					ctx.set_status("请点取墙体（墙体是参数化图元，门窗要开在墙上）")
					return false
				_wall = e as EntWall
				_state = S_POS
				ctx.set_status(prompt())
				return false
			S_POS:
				if _wall == null:
					return false
				var w := width_from_code(_block)
				if w <= 0.0:
					ctx.set_status("无法从编号「%s」解析洞口宽度" % _block)
					_abort()
					return true
				var d := _wall._dist_along_centerline(p)
				if not _wall.add_opening(d, w, _block, _is_window):
					ctx.set_status("此处放不下（与已有洞口重叠或超出墙端），换个位置")
					return false
				ctx.doc.mark_modified(_wall)
				ctx.doc.touch(_wall)
				# 同时插入门窗块，使门扇与开启弧显示出来
				var ins := EntInsert.make(_block, Vector2.ZERO)
				for o in _wall.opening_inserts():
					var cand := o as EntInsert
					if cand.block_name == _block:
						ins = cand
				ins.layer = _wall.layer
				ins.aci = 256
				if ctx.doc.get_block(_block) != null:
					var blk := ctx.doc.get_block(_block)
					for a in blk.attribute_defs:
						var ad: Dictionary = a
						ins.attributes[String(ad.get("tag", ""))] = String(ad.get("default", ""))
				ctx.doc.add_entity(ins)
				_finish()
				ctx.set_status("已插入 %s（洞口宽 %.0f），位置 %.0f" % [_block, w, d])
				return true
		return false

	func on_enter() -> bool:
		if _state == S_BLOCK:
			_state = S_WALL
			ctx.set_status(prompt())
			return false
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_POS or _wall == null:
			return
		var w := width_from_code(_block)
		if w <= 0.0:
			return
		var d := _wall._dist_along_centerline(p)
		var total := _wall._centerline_length()
		var d0 := clampf(d - w * 0.5, 0.0, total)
		var d1 := clampf(d + w * 0.5, 0.0, total)
		var a := view.to_screen(_wall.point_at_dist(d0)["point"])
		var b := view.to_screen(_wall.point_at_dist(d1)["point"])
		ci.draw_line(a, b, Color(1.0, 0.8, 0.3, 0.9), 3.0, true)


# ===========================================================================
# 房间面积
# ===========================================================================

class RoomCmd extends ArchBase:
	enum { S_NAME, S_PICK }
	var _state := S_NAME
	var _name := "房间"

	func cmd_name() -> String:
		return "ROOM"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["rm", "房间"])

	func help_text() -> String:
		return "房间：输入房间名 -> 点取房间内部一点，自动算净面积并标注"

	func start(_args: Dictionary) -> void:
		_begin("标注房间")
		_state = S_NAME
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == S_NAME:
			return "ROOM 输入房间名称 <房间>:"
		return "ROOM 在房间内部点取一点:"

	func on_text(s: String) -> bool:
		if _state != S_NAME:
			return false
		var t := s.strip_edges()
		if t != "":
			_name = t
		_state = S_PICK
		ctx.set_status(prompt())
		return false

	func on_point(p: Vector2) -> bool:
		if _state == S_NAME:
			_state = S_PICK
		# 用墙体轮廓的布尔运算求出开敞空间，取包含点取位置的那一块
		var region := room_polygon_at(ctx.doc, p)
		if region.size() < 3:
			ctx.set_status("该点不在由墙体围合的区域内（房间边界需由墙体构成）")
			return false
		var area_mm2 := absf(_shoelace(region))
		var area_m2 := area_mm2 / 1000000.0
		var c := _centroid(region)
		# 房间名
		var t := EntText.make(c + Vector2(0.0, 120.0), _name, 500.0)
		t.text_style = "房间名_5"
		t.h_align = EntText.HAlign.CENTER
		t.layer = "文字"
		t.aci = 256
		ctx.doc.add_entity(t)
		# 面积（保留一位小数，单位 m²）
		var t2 := EntText.make(c - Vector2(0.0, 400.0), "%.1f m²" % area_m2, 350.0)
		t2.text_style = "标注_2.5"
		t2.h_align = EntText.HAlign.CENTER
		t2.layer = "文字"
		t2.aci = 256
		ctx.doc.add_entity(t2)
		_finish()
		ctx.set_status("房间「%s」净面积 %.2f m²" % [_name, area_m2])
		return true

	func on_enter() -> bool:
		if _state == S_NAME:
			_state = S_PICK
			ctx.set_status(prompt())
			return false
		_abort()
		return true

	func cancel() -> void:
		_abort()

	## 求包含给定点的房间多边形。
	##
	## 用平面剖分面追踪（见 RoomFinder），而不是多边形布尔运算 ——
	## Godot 的 Geometry2D 把"外轮廓"和"洞"混在同一个数组返回，
	## 逐步裁剪会在多步之后把洞丢掉，于是墙体减不掉、面积算成包围盒。
	## 面追踪是精确解，对任意房间形状都成立。
	static func room_polygon_at(doc: CadDocument, p: Vector2) -> PackedVector2Array:
		var walls: Array = []
		for e in doc.entities:
			if not (e is EntWall):
				continue
			var w := e as EntWall
			if not w.visible or not doc.is_layer_visible(w.layer):
				continue
			walls.append(w)
		if walls.is_empty():
			return PackedVector2Array()
		return RoomFinder.find_room(walls, p)

	static func _shoelace(poly: PackedVector2Array) -> float:
		var s := 0.0
		var n := poly.size()
		for i in range(n):
			var a := poly[i]
			var b := poly[(i + 1) % n]
			s += a.x * b.y - b.x * a.y
		return s * 0.5

	static func _centroid(poly: PackedVector2Array) -> Vector2:
		var s := 0.0
		var cx := 0.0
		var cy := 0.0
		var n := poly.size()
		for i in range(n):
			var a := poly[i]
			var b := poly[(i + 1) % n]
			var cr := a.x * b.y - b.x * a.y
			s += cr
			cx += (a.x + b.x) * cr
			cy += (a.y + b.y) * cr
		if absf(s) <= 1.0e-9:
			var sum := Vector2.ZERO
			for q in poly:
				sum += q
			return sum / float(maxi(n, 1))
		return Vector2(cx / (3.0 * s), cy / (3.0 * s))


# ===========================================================================
# 参数化楼梯
# ===========================================================================

class StairCmd extends ArchBase:
	enum { S_PARAMS, S_POS }
	var _state := S_PARAMS
	var _steps := 9
	var _tread := 280.0
	var _flight_w := 1100.0
	var _landing := 1100.0
	var _well := 200.0

	func cmd_name() -> String:
		return "STAIR"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["st", "楼梯"])

	func help_text() -> String:
		return "双跑楼梯：依次输入 踏步数 踏步宽 梯段宽 平台深（回车取默认值）-> 点取插入点"

	func start(_args: Dictionary) -> void:
		_begin("画楼梯")
		_state = S_PARAMS
		ctx.set_status(prompt())

	func prompt() -> String:
		if _state == S_PARAMS:
			return "STAIR 输入 踏步数 踏步宽 梯段宽 平台深 <%d %.0f %.0f %.0f>:" % [
				_steps, _tread, _flight_w, _landing]
		return "STAIR 点取楼梯间左下角:"

	func on_text(s: String) -> bool:
		if _state != S_PARAMS:
			return false
		var t := s.strip_edges()
		if t != "":
			var parts := t.split(" ", false)
			if parts.size() >= 1:
				_steps = maxi(int(parts[0].to_float()), 2)
			if parts.size() >= 2:
				_tread = maxf(parts[1].to_float(), 200.0)
			if parts.size() >= 3:
				_flight_w = maxf(parts[2].to_float(), 700.0)
			if parts.size() >= 4:
				_landing = maxf(parts[3].to_float(), 800.0)
		_state = S_POS
		ctx.set_status(prompt())
		return false

	func on_point(p: Vector2) -> bool:
		if _state == S_PARAMS:
			_state = S_POS
		# 直接用图库里的双跑楼梯块按参数缩放插入，保证画法一致
		var blk := ctx.doc.get_block("双跑楼梯")
		if blk == null:
			ctx.set_status("内置楼梯块缺失")
			_abort()
			return true
		var ins := EntInsert.make("双跑楼梯", p)
		# 按踏步数与踏步宽换算缩放比例（块中原型为 9 级 280 宽）
		var sx := (_tread * float(_steps) + _landing) / (280.0 * 9.0 + 1100.0)
		ins.scale = Vector2(sx, sx)
		ins.layer = "楼梯"
		ins.aci = 256
		ctx.doc.add_entity(ins)
		_finish()
		ctx.set_status("楼梯已插入：%d 级，踏步宽 %.0f，梯段宽 %.0f" % [_steps, _tread, _flight_w])
		return true

	func on_enter() -> bool:
		if _state == S_PARAMS:
			_state = S_POS
			ctx.set_status(prompt())
			return false
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func draw_preview(ci: CanvasItem, view: ViewTransform, p: Vector2) -> void:
		if _state != S_POS:
			return
		var ins := EntInsert.make("双跑楼梯", p)
		var sx := (_tread * float(_steps) + _landing) / (280.0 * 9.0 + 1100.0)
		ins.scale = Vector2(sx, sx)
		_preview_entity(ci, view, ins)


# ===========================================================================
# 门窗表
# ===========================================================================

class ScheduleCmd extends ArchBase:
	func cmd_name() -> String:
		return "SCHEDULE"

	func aliases() -> PackedStringArray:
		return PackedStringArray(["门窗表", "sched"])

	func help_text() -> String:
		return "门窗表：统计图中的门窗洞口，在指定位置生成表格"

	func start(_args: Dictionary) -> void:
		_begin("生成门窗表")
		ctx.set_status(prompt())

	func prompt() -> String:
		return "SCHEDULE 点取门窗表左上角位置:"

	## 统计：从墙体的洞口列表汇总，同时统计孤立的门窗块引用
	static func collect(doc: CadDocument) -> Dictionary:
		var stats := {}
		for e in doc.entities:
			if e is EntWall:
				for o in (e as EntWall).openings:
					var op = o
					var key := String(op.block_name)
					if key == "":
						continue
					if not stats.has(key):
						stats[key] = {"count": 0, "width": op.width, "window": op.is_window}
					(stats[key] as Dictionary)["count"] = int((stats[key] as Dictionary)["count"]) + 1
			elif e is EntInsert:
				var ins := e as EntInsert
				var blk := doc.get_block(ins.block_name)
				if blk == null:
					continue
				var is_win := ins.block_name.begins_with("C")
				var is_door := ins.block_name.begins_with("M")
				if not (is_win or is_door):
					continue
				# 已在墙体洞口里统计过的不重复计
				if _in_wall(doc, ins):
					continue
				var k := ins.block_name
				if not stats.has(k):
					stats[k] = {"count": 0,
						"width": CmdArch.OpeningCmd.width_from_code(k),
						"window": is_win}
				(stats[k] as Dictionary)["count"] = int((stats[k] as Dictionary)["count"]) + 1
		return stats

	static func _in_wall(doc: CadDocument, ins: EntInsert) -> bool:
		for e in doc.entities:
			if not (e is EntWall):
				continue
			for o in (e as EntWall).opening_inserts():
				var cand := o as EntInsert
				if cand.position.distance_to(ins.position) < 1.0 and cand.block_name == ins.block_name:
					return true
		return false

	func on_point(p: Vector2) -> bool:
		var stats := collect(ctx.doc)
		if stats.is_empty():
			ctx.set_status("图中没有检测到门窗（请先用 DOOR/WINDOW 在墙上开洞）")
			_abort()
			return true
		var keys: Array[String] = []
		for k in stats.keys():
			keys.append(String(k))
		keys.sort()
		var rows := keys.size()
		var row_h := 800.0
		var cols := [2200.0, 1400.0, 1400.0, 1200.0, 2600.0]
		var total_w := 0.0
		for c in cols:
			total_w += float(c)
		var total_h := row_h * float(rows + 2)
		var lay := "尺寸标注"
		# 表格线
		for i in range(rows + 3):
			var y := p.y - float(i) * row_h
			CmdArch._line(ctx.doc, lay, Vector2(p.x, y), Vector2(p.x + total_w, y))
		var x := p.x
		CmdArch._line(ctx.doc, lay, Vector2(x, p.y), Vector2(x, p.y - total_h))
		for c in cols:
			x += float(c)
			CmdArch._line(ctx.doc, lay, Vector2(x, p.y), Vector2(x, p.y - total_h))
		# 表头
		var headers := ["门窗编号", "洞口宽", "洞口高", "数量", "备注"]
		x = p.x
		for i in range(headers.size()):
			CmdArch._center_text(ctx.doc, Vector2(x + float(cols[i]) * 0.5, p.y - row_h * 0.5), headers[i], 350.0)
			x += float(cols[i])
		# 标题
		CmdArch._center_text(ctx.doc, Vector2(p.x + total_w * 0.5, p.y + row_h * 0.6), "门窗表", 500.0)
		# 数据行
		for r in range(rows):
			var k := keys[r]
			var st: Dictionary = stats[k]
			var code := k
			var w := float(st["width"])
			# 高从编号解析
			var h := 0.0
			if code.length() >= 5:
				h = float(code.substr(3, 2).to_int()) * 100.0
			var y := p.y - row_h * float(r + 1) - row_h * 0.5
			var vals := [code, "%.0f" % w, "%.0f" % h, str(int(st["count"])),
				"窗" if bool(st["window"]) else "门"]
			x = p.x
			for i in range(vals.size()):
				CmdArch._center_text(ctx.doc, Vector2(x + float(cols[i]) * 0.5, y), vals[i], 320.0)
				x += float(cols[i])
		_finish()
		ctx.set_status("门窗表已生成：共 %d 种规格" % rows)
		return true

	func on_enter() -> bool:
		_abort()
		return true

	func cancel() -> void:
		_abort()

	func on_mouse_move(_p: Vector2) -> void:
		pass


static func _line(doc: CadDocument, layer: String, a: Vector2, b: Vector2) -> void:
	var e := EntLine.make(a, b)
	e.layer = layer
	e.aci = 256
	e.lineweight = 0.5
	doc.add_entity(e, false)


static func _center_text(doc: CadDocument, pos: Vector2, s: String, h: float) -> void:
	var t := EntText.make(pos, s, h)
	t.text_style = "仿宋_3.5"
	t.h_align = EntText.HAlign.CENTER
	t.v_align = EntText.VAlign.MIDDLE
	t.layer = "文字"
	t.aci = 256
	doc.add_entity(t, false)
