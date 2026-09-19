class_name CadViewport
extends Control
## 绘图区。负责：国标图纸底（栅格/坐标轴）、图元渲染、鼠标交互、命令驱动。
##
## 视口采用"图纸底色 + 细栅格"的工程图样式（深底浅线），
## 便于长时间制图，也是国内 CAD 的默认观感。

signal cursor_moved(model_pos: Vector2)
signal command_prompt_changed(text: String)

## 图纸底色
var bg_color: Color = Color(0.075, 0.082, 0.098)
## 栅格主/次线颜色
var grid_major_color: Color = Color(0.20, 0.22, 0.26, 0.65)
var grid_minor_color: Color = Color(0.145, 0.16, 0.19, 0.55)
## 坐标轴颜色（X 红、Y 绿，与 CAD 一致）
var axis_x_color: Color = Color(0.55, 0.22, 0.22)
var axis_y_color: Color = Color(0.22, 0.5, 0.24)
## 十字光标
var crosshair_color: Color = Color(0.75, 0.80, 0.88, 0.55)
var crosshair_size_px: float = 26.0
var show_crosshair: bool = true
var show_grid: bool = true
var show_axes: bool = true

var doc: CadDocument
var view: ViewTransform = ViewTransform.new()
var renderer: CadRenderer = CadRenderer.new()
var ctx: CommandContext = CommandContext.new()

## 当前命令
var active_command: CadCommand = null
## 最近一次使用的命令（空格/回车重复）
var _last_command_name: String = ""

var mouse_model: Vector2 = Vector2.ZERO
var mouse_screen: Vector2 = Vector2.ZERO
var _panning := false
var _pan_anchor := Vector2.ZERO
var _mouse_inside := false


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	ctx.viewport = self
	resized.connect(_on_resized)
	_on_resized()


func setup(p_doc: CadDocument) -> void:
	doc = p_doc
	ctx.doc = p_doc
	ctx.view = view
	_on_resized()
	queue_redraw()


func _on_resized() -> void:
	view.set_view_size(size)


func set_prompt(text: String) -> void:
	command_prompt_changed.emit(text)


# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color)
	if show_grid:
		_draw_grid()
	if show_axes:
		_draw_axes()
	if doc != null:
		renderer.ltscale = doc.ltscale
		renderer.draw(doc, view, self)
	if active_command != null:
		active_command.draw_preview(self, view, mouse_model)
	if show_crosshair and _mouse_inside:
		_draw_crosshair()


## 自适应栅格：从 1-2-5 数列里挑一个间距，使屏幕上落在 10~100px 之间。
## 这样任何缩放级别下栅格都疏密适中，不会糊成一片或稀到看不见。
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
	# 次栅格（1/5 主格）只在细格间距够大时才画；
	# 否则屏幕上是一片细密噪点，反而干扰读图。
	var minor_step := step / 5.0
	var draw_minor := minor_step * view.zoom >= 8.0

	var x0 := floorf(vr.position.x / step) * step
	var y0 := floorf(vr.position.y / step) * step
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

	var gx := x0
	while gx <= x1:
		var sx := view.to_screen(Vector2(gx, 0)).x
		draw_line(Vector2(sx, 0), Vector2(sx, size.y), grid_major_color, 1.0, false)
		gx += step
	var gy := y0
	while gy <= y1:
		var sy := view.to_screen(Vector2(0, gy)).y
		draw_line(Vector2(0, sy), Vector2(size.x, sy), grid_major_color, 1.0, false)
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


# ---------------------------------------------------------------------------
# 输入
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_screen = event.position
		mouse_model = view.to_model(event.position)
		_mouse_inside = true
		if _panning:
			view.pan_by_pixels(event.position - _pan_anchor)
			_pan_anchor = event.position
		if active_command != null:
			active_command.on_mouse_move(mouse_model)
		cursor_moved.emit(mouse_model)
		queue_redraw()
		return

	if event is InputEventMouseButton:
		_handle_button(event)
		return


func _handle_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				view.zoom_at(event.position, 1.18)
				queue_redraw()
				cursor_moved.emit(view.to_model(event.position))
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				view.zoom_at(event.position, 1.0 / 1.18)
				queue_redraw()
				cursor_moved.emit(view.to_model(event.position))
		MOUSE_BUTTON_MIDDLE:
			# 中键拖动平移（国内 CAD 习惯）
			_panning = event.pressed
			_pan_anchor = event.position
			mouse_default_cursor_shape = Control.CURSOR_DRAG if _panning else Control.CURSOR_CROSS
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				grab_focus()
				_on_left_click(event.position)
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_on_right_click()


func _on_left_click(screen_pos: Vector2) -> void:
	if active_command == null:
		return
	var p := view.to_model(screen_pos)
	if active_command.on_point(p):
		_end_command()


func _on_right_click() -> void:
	# 右键 = 回车（AutoCAD 习惯）：结束当前命令或重复上一条
	if active_command != null:
		if active_command.on_enter():
			_end_command()
	else:
		repeat_last_command()


# ---------------------------------------------------------------------------
# 命令驱动
# ---------------------------------------------------------------------------

func start_command(cmd: CadCommand, args := {}) -> void:
	if active_command != null:
		active_command.cancel()
		active_command = null
	active_command = cmd
	_last_command_name = cmd.cmd_name()
	cmd.ctx = ctx
	cmd.start(args)
	if cmd.finished:
		active_command = null
	queue_redraw()


func _end_command() -> void:
	if active_command != null:
		active_command.finished = true
	active_command = null
	command_prompt_changed.emit("")
	queue_redraw()


func cancel_command() -> void:
	if active_command == null:
		return
	active_command.cancel()
	active_command = null
	command_prompt_changed.emit("")
	queue_redraw()


func repeat_last_command() -> void:
	if _last_command_name == "":
		return
	match _last_command_name:
		"LINE":
			start_command(CmdLine.new())


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
	# 无活动命令时，把输入当作命令名
	if t == "":
		repeat_last_command()
		return true
	return run_command_by_name(t)


## 按名字或别名启动命令
func run_command_by_name(name: String) -> bool:
	var n := name.strip_edges().to_lower()
	if n == "line" or n == "l" or n == "直线":
		start_command(CmdLine.new())
		return true
	if n == "u" or n == "undo" or n == "撤销":
		undo()
		return true
	if n == "redo" or n == "重做":
		redo()
		return true
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
			# 空格与回车等价：结束当前命令，或重复上一条命令
			if active_command != null:
				if active_command.on_enter():
					_end_command()
			else:
				repeat_last_command()
			accept_event()
