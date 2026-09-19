class_name CadViewport
extends Control
## 绘图区。负责：图纸底（栅格/坐标轴）、图元渲染、鼠标交互、选择、夹点编辑、命令驱动。
##
## 输入分派优先级（自上而下）：
##   1. 正在拖动夹点          -> 夹点编辑
##   2. 命令处于"选择对象"阶段 -> 拾取/框选构建选择集
##   3. 有活动命令且需要点输入 -> 把点交给命令
##   4. 无命令                -> 预选择（拾取/框选），供后续命令使用

signal cursor_moved(model_pos: Vector2)
signal command_prompt_changed(text: String)
signal selection_changed(count: int)
signal command_started(name: String)
signal command_finished()
signal snap_changed()

## 图纸底色
var bg_color: Color = Color(0.075, 0.082, 0.098)
var grid_major_color: Color = Color(0.20, 0.22, 0.26, 0.65)
var grid_minor_color: Color = Color(0.145, 0.16, 0.19, 0.55)
var axis_x_color: Color = Color(0.55, 0.22, 0.22)
var axis_y_color: Color = Color(0.22, 0.5, 0.24)
var crosshair_color: Color = Color(0.75, 0.80, 0.88, 0.55)
var crosshair_size_px: float = 26.0
var pick_aperture_px: float = 8.0
var show_crosshair: bool = true
var show_grid: bool = true
var show_axes: bool = true

enum Mode { IDLE, BOX_SELECT, GRIP_DRAG }
var _mode: int = Mode.IDLE
var _press_screen := Vector2.ZERO
var _drag_screen := Vector2.ZERO
var _grip_hit: Dictionary = {}
var _grip_moved := false

var doc: CadDocument = null
var view: ViewTransform = ViewTransform.new()
var renderer: CadRenderer = CadRenderer.new()
var ctx: CommandContext = CommandContext.new()
var index: SpatialIndex = null
## 索引对应的文档版本号。与渲染缓存同一套过期判断机制。
var _index_revision := -1
## 索引重建次数。供测试与基准观察"合并重建"是否真的生效。
var index_builds := 0
var snap: SnapEngine = SnapEngine.new()
## 最近一次捕捉结果，用于绘制标记与状态栏显示
var _last_snap: SnapEngine.Result = null
## 最近的捕捉命中点（屏幕坐标），用于画追踪虚线
var _snap_screen := Vector2.ZERO
## 是否正在用捕捉结果（决定要不要画标记）
var _snap_active := false

var active_command: CadCommand = null
var _last_command_name: String = ""

var mouse_model: Vector2 = Vector2.ZERO
var mouse_screen: Vector2 = Vector2.ZERO
var _panning := false
var _pan_anchor := Vector2.ZERO
var _mouse_inside := false
## 图框几何缓存：图纸空间下按布局参数生成一次，避免每帧重建
var _frame_doc: CadDocument = null
var _frame_key := ""


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	ctx.viewport = self
	resized.connect(_on_resized)
	_on_resized()


func setup(p_doc: CadDocument) -> void:
	if doc != null and doc.changed.is_connected(_on_doc_changed):
		doc.changed.disconnect(_on_doc_changed)
	doc = p_doc
	ctx.doc = p_doc
	ctx.view = view
	ctx.selection.clear()
	ctx.index_provider = Callable(self, "spatial_index")
	active_command = null
	doc.changed.connect(_on_doc_changed)
	# 换文档：旧索引作废，留给第一次用到时再建
	index = null
	_index_revision = -1
	index_builds = 0
	_on_resized()
	selection_changed.emit(0)
	queue_redraw()


func _on_doc_changed() -> void:
	# 只重绘，不重建索引 —— 索引留到真正被用到时（拾取/框选/捕捉）再建。
	# 批量操作会连发 N 次本回调（删除/复制/阵列 N 个图元各一次），
	# 若在这里重建，十万图元下删 5 个图元就要重建 5 次、卡 3.2 秒。
	queue_redraw()


## 取空间索引，按需重建。
##
## 过期判断用**文档版本号**（与渲染缓存同一套机制）：任何变更都会 bump 版本，
## 所以这里拿到的索引一定是最新的；而 N 次连续变更只会触发一次重建 ——
## 因为中间的变更没人来取索引。
func spatial_index() -> SpatialIndex:
	if doc == null:
		index = null
		_index_revision = -1
		return null
	if index != null and _index_revision == doc.revision:
		return index
	index = SpatialIndex.build(doc.entities, _index_area())
	_index_revision = doc.revision
	index_builds += 1
	return index


## 索引覆盖的区域：图元总包围盒外扩一成。空文档给一个兜底区域。
func _index_area() -> Rect2:
	var bb := doc.get_bbox()
	if doc.entity_count() == 0 or (bb.size.x <= 0.0 and bb.size.y <= 0.0):
		bb = Rect2(-1000.0, -1000.0, 2000.0, 2000.0)
	return bb.grow(maxf(bb.size.x, bb.size.y) * 0.1 + 1.0)


## 强制立刻重建索引。测试与基准用；正常交互走 spatial_index() 的惰性路径。
func rebuild_index() -> void:
	_index_revision = -1
	spatial_index()


func _on_resized() -> void:
	view.set_view_size(size)


func set_prompt(text: String) -> void:
	command_prompt_changed.emit(text)


func selection_items() -> Array[CadEntity]:
	return ctx.selection.items


## 供命令在改动选择集后主动通知界面
func notify_selection_changed() -> void:
	selection_changed.emit(ctx.selection.size())
	if prop_panel_ref != null and is_instance_valid(prop_panel_ref):
		prop_panel_ref.call("refresh")
	queue_redraw()


## 特性面板的引用（由主窗口注入），命令改了选择集后需要刷新它
var prop_panel_ref: Object = null


## 把屏幕坐标解析为实际的输入点（经对象捕捉/正交/极轴/栅格处理）。
## 命令的橡皮筋基点作为追踪参考，使垂足、切点、极轴能正常工作。
func snapped_model(screen_pos: Vector2) -> Vector2:
	var raw := view.to_model(screen_pos)
	var from = active_command.points[active_command.points.size() - 1] if (
			active_command != null and active_command.points.size() > 0) else null
	var r := snap.resolve(doc, spatial_index(), view, raw, from)
	_last_snap = r if r.hit else null
	if r.hit:
		_snap_screen = view.to_screen(r.point)
	return r.point


## 仅用于预览显示，不产生副作用
func _snapped_for_preview() -> Vector2:
	if active_command == null:
		return mouse_model
	var from = active_command.points[active_command.points.size() - 1] if active_command.points.size() > 0 else null
	var r := snap.resolve(doc, spatial_index(), view, mouse_model, from)
	_last_snap = r if r.hit else null
	if r.hit:
		_snap_screen = view.to_screen(r.point)
		_snap_active = true
	# 悬停获取追踪基准点：停在同一捕捉点上足够久即记为基准
	if snap.update_hover(r, Time.get_ticks_msec()):
		pass
	return r.point


# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------

## 当前是否处于图纸空间
func is_layout_mode() -> bool:
	return doc != null and doc.current_layout() != null


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color)
	if is_layout_mode():
		_draw_layout()
		return
	if show_grid:
		_draw_grid()
	if show_axes:
		_draw_axes()
	if doc != null:
		renderer.ltscale = doc.ltscale
		renderer.draw(doc, view, self, ctx.selection.items)
	_snap_active = false
	var preview_p := mouse_model
	if active_command != null:
		preview_p = _snapped_for_preview()
		active_command.draw_preview(self, view, preview_p)
	# 追踪对齐轴：只在命令进行中显示（追踪本来就是命令内的辅助）
	if active_command != null:
		snap.draw_tracking(self, view, _last_snap)
	# 捕捉标记：只在命令取点或待命状态下显示，便于预览将要落在哪里
	if _last_snap != null and _last_snap.hit and (_mouse_inside or _snap_active):
		var origin = view.to_screen(_last_snap.track_from) if _last_snap.has_track else null
		snap.draw_marker(self, _snap_screen, _last_snap, ThemeDB.fallback_font, origin, _snap_active)
	# 夹点只在无活动命令时显示（编辑命令进行中会干扰视线）
	if ctx.selection.size() > 0 and active_command == null:
		var hot_e: CadEntity = _grip_hit.get("entity")
		var hot_i: int = int(_grip_hit.get("index", -1))
		renderer.draw_grips(view, self, ctx.selection.items, hot_e, hot_i)
	if _mode == Mode.BOX_SELECT:
		_draw_selection_box()
	if show_crosshair and _mouse_inside:
		_draw_crosshair()


## 图纸空间绘制。
##
## 坐标语义：此时 view.center / view.zoom 按**图纸毫米**解释，
## 于是纸张、图框、标题栏都以 1:1 的真实图纸尺寸绘制。
## 每个视口再把模型内容经「模型 -> 图纸 -> 屏幕」的复合变换画进来，
## 并裁剪到视口边界 —— 不裁剪的话视口外的模型会溢到图纸其他区域上。
func _draw_layout() -> void:
	var layout := doc.current_layout()
	if layout == null:
		return
	# 纸张
	var paper := layout.paper_size()
	var p0 := view.to_screen(Vector2.ZERO)
	var p1 := view.to_screen(paper)
	var pr := Rect2(p0, Vector2.ZERO).merge(Rect2(p1, Vector2.ZERO))
	draw_rect(pr, Color(0.97, 0.97, 0.95))
	draw_rect(pr, Color(0.35, 0.38, 0.42), false, 1.0)

	# 图框 + 标题栏 + 会签栏（按布局参数缓存）
	_draw_frame(layout)

	# 各视口内的模型内容
	for v in layout.viewports:
		_draw_paper_view(layout, v as CadLayout.PaperView)


func _draw_frame(layout: CadLayout) -> void:
	var key := "%s|%s|%s" % [layout.format, str(layout.portrait), str(layout.title_fields)]
	if _frame_doc == null or key != _frame_key:
		var fd := CadDocument.new()
		fd.plot_scale = 1.0
		GbSheet.build_frame(fd, layout.format, layout.portrait, layout.title_fields)
		_frame_doc = fd
		_frame_key = key
	# 图框按 1:1 图纸尺寸生成，与纸张空间的坐标语义一致，直接画
	renderer.ltscale = 1.0
	renderer.clip_enabled = false
	renderer.draw(_frame_doc, view, self)


func _draw_paper_view(layout: CadLayout, vp: CadLayout.PaperView) -> void:
	# 视口边界：出图时默认不打印，故用浅色提示，屏幕上仍可见
	var a := view.to_screen(vp.paper_rect.position)
	var b := view.to_screen(vp.paper_rect.position + vp.paper_rect.size)
	var screen_rect := Rect2(a, Vector2.ZERO).merge(Rect2(b, Vector2.ZERO))
	if not vp.print_border:
		draw_rect(screen_rect, Color(0.45, 0.55, 0.65, 0.5), false, 1.0)

	# 复合变换：模型 -> 图纸 -> 屏幕。
	# 设图纸视图为 (center=vc, zoom=vz)、视口比例为 s、视口中心为 pc（图纸坐标）、
	# 模型中心为 mc，则复合后等价于 zoom = vz/s、center = mc - (pc - vc)*s。
	var vp_view := ViewTransform.new()
	vp_view.set_view_size(view.view_size)
	vp_view.zoom = view.zoom / maxf(vp.scale, 1.0e-9)
	vp_view.center = vp.model_center - (vp.paper_rect.position + vp.paper_rect.size * 0.5 - view.center) * vp.scale

	renderer.ltscale = doc.ltscale
	renderer.clip_enabled = true
	renderer.clip_rect = screen_rect
	# 线宽要按**纸张缩放**换算，而不是固定常数：
	# 布局的意义就是所见即所得，1.0mm 的墙线在纸上必须真的是 1.0mm。
	# view.zoom 此时正是「图纸毫米 -> 像素」，直接拿它当 px_per_mm。
	var saved_px := renderer.px_per_mm
	renderer.px_per_mm = view.zoom
	renderer.draw(doc, vp_view, self, [])
	renderer.px_per_mm = saved_px
	renderer.clip_enabled = false


## 进入图纸空间。若尚无布局则按当前图形范围新建一个。
func enter_layout() -> void:
	if doc == null:
		return
	var bb := doc.get_bbox()
	var layout := doc.ensure_layout()
	layout.fit_model_to_paper(bb)
	doc.active_layout = 0
	_frame_key = ""
	# 视图切到纸张坐标：让整张纸铺满视口
	var paper := layout.paper_size()
	view.zoom = minf(size.x / maxf(paper.x, 1.0), size.y / maxf(paper.y, 1.0)) * 0.92
	view.center = paper * 0.5
	queue_redraw()


## 回到模型空间
func exit_layout() -> void:
	if doc == null:
		return
	doc.active_layout = -1
	zoom_extents()


## 让布局的视口恰好框住当前图形范围
func fit_layout_to_drawing() -> void:
	if doc == null:
		return
	var layout := doc.current_layout()
	if layout == null:
		return
	layout.fit_model_to_paper(doc.get_bbox())
	_frame_key = ""
	queue_redraw()


## 自适应栅格：从 1-2-5 数列里挑一个间距，使屏幕上落在合理范围。
func _grid_spacing_mm() -> float:
	var target_px := 24.0
	var raw := target_px / maxf(view.zoom, 1.0e-9)
	var exp10 := floorf(log(raw) / log(10.0))
	var base := pow(10.0, exp10)
	var m := raw / base
	var mult := 1.0
	if m <= 1.0:
		mult = 1.0
	elif m <= 2.0:
		mult = 2.0
	elif m <= 5.0:
		mult = 5.0
	else:
		mult = 10.0
	return base * mult


func _draw_grid() -> void:
	var step := _grid_spacing_mm()
	if step <= 0.0:
		return
	var vr := view.visible_rect()
	var step_px := step * view.zoom
	var minor_step := step / 5.0
	var draw_minor := minor_step * view.zoom >= 8.0

	var x1 := vr.position.x + vr.size.x
	var y1 := vr.position.y + vr.size.y

	if draw_minor:
		var mx0 := floorf(vr.position.x / minor_step) * minor_step
		var my0 := floorf(vr.position.y / minor_step) * minor_step
		var x := mx0
		while x <= x1:
			var sx := view.to_screen(Vector2(x, 0)).x
			draw_line(Vector2(sx, 0), Vector2(sx, size.y), grid_minor_color, 1.0, false)
			x += minor_step
		var y := my0
		while y <= y1:
			var sy := view.to_screen(Vector2(0, y)).y
			draw_line(Vector2(0, sy), Vector2(size.x, sy), grid_minor_color, 1.0, false)
			y += minor_step

	var gx := floorf(vr.position.x / step) * step
	while gx <= x1:
		var sx2 := view.to_screen(Vector2(gx, 0)).x
		draw_line(Vector2(sx2, 0), Vector2(sx2, size.y), grid_major_color, 1.0, false)
		gx += step
	var gy := floorf(vr.position.y / step) * step
	while gy <= y1:
		var sy2 := view.to_screen(Vector2(0, gy)).y
		draw_line(Vector2(0, sy2), Vector2(size.x, sy2), grid_major_color, 1.0, false)
		gy += step


func _draw_axes() -> void:
	var o := view.to_screen(Vector2.ZERO)
	if o.y >= 0.0 and o.y <= size.y:
		draw_line(Vector2(0, o.y), Vector2(size.x, o.y), axis_x_color, 1.0, false)
	if o.x >= 0.0 and o.x <= size.x:
		draw_line(Vector2(o.x, 0), Vector2(o.x, size.y), axis_y_color, 1.0, false)


func _draw_crosshair() -> void:
	var p := mouse_screen
	var h := crosshair_size_px
	draw_line(Vector2(p.x - h, p.y), Vector2(p.x + h, p.y), crosshair_color, 1.0, false)
	draw_line(Vector2(p.x, p.y - h), Vector2(p.x, p.y + h), crosshair_color, 1.0, false)
	# 靶框与拾取容差一致，便于预判能否选中
	var a := pick_aperture_px
	draw_rect(Rect2(p - Vector2(a, a), Vector2(a, a) * 2.0), Color(0.5, 0.6, 0.7, 0.28), false, 1.0)


## 窗选用实线框、交叉选用虚线框 —— 与 CAD 的视觉约定一致
func _draw_selection_box() -> void:
	var r := Rect2(_press_screen, Vector2.ZERO).merge(Rect2(_drag_screen, Vector2.ZERO))
	var crossing := _drag_screen.x < _press_screen.x
	var col := Color(0.45, 0.7, 1.0, 0.9) if crossing else Color(0.45, 0.9, 0.55, 0.9)
	draw_rect(r, Color(col.r, col.g, col.b, 0.10), true)
	if crossing:
		_dashed_rect(r, col)
	else:
		draw_rect(r, col, false, 1.0)


func _dashed_rect(r: Rect2, col: Color) -> void:
	var c := [
		r.position,
		r.position + Vector2(r.size.x, 0),
		r.position + r.size,
		r.position + Vector2(0, r.size.y),
	]
	for i in range(4):
		_dashed_line(c[i], c[(i + 1) % 4], col)


func _dashed_line(a: Vector2, b: Vector2, col: Color) -> void:
	var total := a.distance_to(b)
	if total <= 0.1:
		return
	var dir := (b - a) / total
	var pos := 0.0
	var on := true
	while pos < total:
		var step := minf(6.0, total - pos)
		if on:
			draw_line(a + dir * pos, a + dir * (pos + step), col, 1.0, false)
		pos += step
		on = not on


# ---------------------------------------------------------------------------
# 输入
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_on_motion(event)
		return
	if event is InputEventMouseButton:
		_on_button(event)
		return


func _on_motion(event: InputEventMouseMotion) -> void:
	mouse_screen = event.position
	mouse_model = view.to_model(event.position)
	_mouse_inside = true
	if _panning:
		view.pan_by_pixels(event.position - _pan_anchor)
		_pan_anchor = event.position
	match _mode:
		Mode.BOX_SELECT:
			_drag_screen = event.position
		Mode.GRIP_DRAG:
			_drag_screen = event.position
			if _press_screen.distance_to(event.position) > 3.0:
				_grip_moved = true
	if active_command != null:
		active_command.on_mouse_move(mouse_model)
	cursor_moved.emit(mouse_model)
	queue_redraw()


func _on_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				view.zoom_at(event.position, 1.18)
				queue_redraw()
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				view.zoom_at(event.position, 1.0 / 1.18)
				queue_redraw()
		MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
			_pan_anchor = event.position
			mouse_default_cursor_shape = Control.CURSOR_DRAG if _panning else Control.CURSOR_CROSS
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				# 双击文字直接进入改文字命令（CAD 的通用习惯）
				if event.double_click and active_command == null:
					if _try_edit_text_at(event.position):
						return
				_on_left_down(event.position)
			else:
				_on_left_up(event.position)
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_on_right_click()


## 双击文字图元时启动改文字命令。返回是否已处理。
func _try_edit_text_at(screen_pos: Vector2) -> bool:
	var m := view.to_model(screen_pos)
	var tol := view.tolerance_for_pixels(pick_aperture_px)
	var e := CadSelection.pick(doc, spatial_index(), m, tol)
	if e == null or not (e is EntText or e is EntMText):
		return false
	start_command(CmdText.TextChange.new(), {"entity": e})
	return true


func _on_left_down(screen_pos: Vector2) -> void:
	grab_focus()
	_press_screen = screen_pos
	_drag_screen = screen_pos
	_grip_moved = false

	# 1) 夹点优先：无活动命令且选中集非空时，检查是否点中夹点
	if active_command == null and ctx.selection.size() > 0:
		_grip_hit = renderer.hit_grip(view, ctx.selection.items, screen_pos)
		if not _grip_hit.is_empty():
			_mode = Mode.GRIP_DRAG
			doc.begin_transaction("夹点编辑")
			queue_redraw()
			return

	# 2) 命令需要点输入时，按下即取点（CAD 习惯：单击确定一个点）
	if active_command != null and not active_command.is_selecting():
		var sp := snapped_model(screen_pos)
		if active_command.on_point(sp):
			_end_command()
		queue_redraw()
		return

	# 3) 其余情况进入框选；没有拖动时松开按单击拾取处理
	_mode = Mode.BOX_SELECT
	queue_redraw()


func _on_left_up(screen_pos: Vector2) -> void:
	var dragged := _press_screen.distance_to(screen_pos) > 3.0
	match _mode:
		Mode.GRIP_DRAG:
			_finish_grip_drag(screen_pos)
		Mode.BOX_SELECT:
			if dragged:
				_apply_box_selection(_press_screen, screen_pos)
			else:
				_apply_pick(screen_pos)
		Mode.IDLE:
			pass
	_mode = Mode.IDLE
	_grip_hit = {}
	queue_redraw()


func _finish_grip_drag(screen_pos: Vector2) -> void:
	var e: CadEntity = _grip_hit.get("entity")
	var i: int = int(_grip_hit.get("index", -1))
	if not _grip_moved or e == null or i < 0:
		doc.rollback_transaction()
		return
	doc.mark_modified(e)
	e.move_grip(i, view.to_model(screen_pos))
	doc.touch(e)
	doc.commit_transaction()


func _on_right_click() -> void:
	# 右键 = 回车（AutoCAD 习惯）：结束当前命令或重复上一条
	if active_command != null:
		if active_command.on_enter():
			_end_command()
	elif ctx.selection.size() > 0 and _last_command_name != "":
		repeat_last_command()
	else:
		ctx.selection.clear()
		selection_changed.emit(0)
		queue_redraw()


# ---------------------------------------------------------------------------
# 选择
# ---------------------------------------------------------------------------

func _apply_pick(screen_pos: Vector2) -> void:
	var m := view.to_model(screen_pos)
	var tol := view.tolerance_for_pixels(pick_aperture_px)
	var e := CadSelection.pick(doc, spatial_index(), m, tol)
	if e == null:
		ctx.selection.clear()
		selection_changed.emit(0)
		return
	ctx.selection.toggle(e)
	selection_changed.emit(ctx.selection.size())


func _apply_box_selection(a: Vector2, b: Vector2) -> void:
	var r := Rect2(a, Vector2.ZERO).merge(Rect2(b, Vector2.ZERO))
	var m0 := view.to_model(r.position)
	var m1 := view.to_model(r.position + r.size)
	var mr := Rect2(Vector2(minf(m0.x, m1.x), minf(m0.y, m1.y)),
		Vector2(absf(m1.x - m0.x), absf(m1.y - m0.y)))
	# 左->右 为窗选（完全在内），右->左 为交叉选（相交即选）
	var found: Array[CadEntity]
	if b.x < a.x:
		found = CadSelection.crossing_select(doc, spatial_index(), mr)
	else:
		found = CadSelection.window_select(doc, spatial_index(), mr)
	# Shift 为从选择集中移除
	var remove_mode := Input.is_key_pressed(KEY_SHIFT)
	for e in found:
		if remove_mode:
			ctx.selection.remove(e)
		else:
			ctx.selection.add(e)
	selection_changed.emit(ctx.selection.size())


# ---------------------------------------------------------------------------
# 命令驱动
# ---------------------------------------------------------------------------

func start_command(cmd: CadCommand, args := {}) -> void:
	if cmd == null:
		return
	if active_command != null:
		active_command.cancel()
		active_command = null
	active_command = cmd
	_last_command_name = cmd.cmd_name()
	# 命令边界清空追踪基准：跨命令的基准没有意义，
	# 留着反而会在新命令里造成误吸附
	snap.clear_tracking()
	cmd.ctx = ctx
	cmd.start(args)
	command_started.emit(_last_command_name)
	if cmd.finished:
		_end_command()
	else:
		ctx.set_status(cmd.prompt())
	queue_redraw()


func _end_command() -> void:
	if active_command != null:
		active_command.finished = true
		active_command = null
	snap.clear_tracking()
	command_prompt_changed.emit("")
	command_finished.emit()
	selection_changed.emit(ctx.selection.size())
	queue_redraw()


func cancel_command() -> void:
	if active_command == null:
		if ctx.selection.size() > 0:
			ctx.selection.clear()
			selection_changed.emit(0)
			queue_redraw()
		return
	active_command.cancel()
	active_command = null
	snap.clear_tracking()
	command_prompt_changed.emit("")
	command_finished.emit()
	queue_redraw()


func repeat_last_command() -> void:
	if _last_command_name != "":
		run_command(_last_command_name)


## 按名称或别名启动命令
func run_command(name: String) -> bool:
	var cmd := CommandRegistry.create(name)
	if cmd == null:
		return false
	start_command(cmd)
	return true


## 命令行提交的文本
func submit_text(text: String) -> bool:
	var t := text.strip_edges()
	if active_command != null:
		if t == "":
			if active_command.on_enter():
				_end_command()
			return true
		if active_command.on_text(t):
			_end_command()
		queue_redraw()
		return true
	if t == "":
		repeat_last_command()
		return true
	if CommandRegistry.is_command(t):
		return run_command(t)
	return false


func undo() -> bool:
	if doc == null:
		return false
	cancel_command()
	var ok := doc.undo_last()
	queue_redraw()
	return ok


func redo() -> bool:
	if doc == null:
		return false
	cancel_command()
	var ok := doc.redo_last()
	queue_redraw()
	return ok


func select_all() -> void:
	ctx.selection.clear()
	for e in doc.entities:
		if e.visible:
			ctx.selection.add(e)
	selection_changed.emit(ctx.selection.size())
	queue_redraw()


func delete_selection() -> void:
	if ctx.selection.is_empty():
		return
	doc.begin_transaction("删除")
	for e in ctx.selection.items:
		doc.remove_entity(e)
	doc.commit_transaction()
	ctx.selection.clear()
	selection_changed.emit(0)
	queue_redraw()


func zoom_extents() -> void:
	if doc == null:
		return
	var bb := doc.get_bbox()
	if bb.size.x <= 0.0 and bb.size.y <= 0.0:
		view.reset()
	else:
		view.zoom_to_fit(bb.grow(maxf(bb.size.x, bb.size.y) * 0.05))
	queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var k := event as InputEventKey
	match k.keycode:
		KEY_ESCAPE:
			cancel_command()
			accept_event()
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if active_command != null:
				if active_command.on_enter():
					_end_command()
			else:
				repeat_last_command()
			accept_event()
		KEY_DELETE:
			delete_selection()
			accept_event()
		KEY_F3:
			snap.osnap_enabled = not snap.osnap_enabled
			snap_changed.emit()
			queue_redraw()
			accept_event()
		KEY_F8:
			snap.ortho = not snap.ortho
			snap_changed.emit()
			accept_event()
		KEY_F9:
			snap.grid_snap = not snap.grid_snap
			snap_changed.emit()
			accept_event()
		KEY_F10:
			snap.polar_enabled = not snap.polar_enabled
			snap_changed.emit()
			accept_event()
		KEY_F11:
			snap.tracking_enabled = not snap.tracking_enabled
			if not snap.tracking_enabled:
				snap.clear_tracking()
			snap_changed.emit()
			queue_redraw()
			accept_event()
