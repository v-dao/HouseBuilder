class_name CadCommand
extends RefCounted
## 命令基类。每个命令是一个小状态机，由 CadViewport 驱动。
##
## 生命周期：
##   start() -> 反复 on_point()/on_text()/on_option() -> 直到某个回调返回 true 表示结束
##   随时可能被 cancel() 打断（Esc）
##
## 所有对文档的修改都必须在 begin()/commit() 事务内完成，撤销栈才能正确记录。

## 命令上下文，由 CadViewport 注入
var ctx: CommandContext = null

## 命令是否已结束
var finished: bool = false

## 已采集的点
var points: PackedVector2Array = PackedVector2Array()


## 命令名（大写，如 "LINE"）
func cmd_name() -> String:
	return ""


## 别名（小写，命令行可用）
func aliases() -> PackedStringArray:
	return PackedStringArray()


## 简短说明，用于帮助
func help_text() -> String:
	return ""


## 命令开始。ctx 已就绪。
func start(_args: Dictionary) -> void:
	pass


## 收到了一个点（已过捕捉处理）
## 返回 true 表示命令结束
func on_point(_p: Vector2) -> bool:
	return false


## 命令行输入了一段文字（可解析为坐标、距离、选项关键字）
## 返回 true 表示命令结束
func on_text(_s: String) -> bool:
	return false


## 按了回车/空格
## 返回 true 表示命令结束
func on_enter() -> bool:
	return true


## 鼠标移动（未点击），用于更新橡皮筋
func on_mouse_move(_p: Vector2) -> void:
	pass


## 取消。需自行回滚未提交的改动。
func cancel() -> void:
	pass


## 当前应显示在命令行与光标附近的提示
func prompt() -> String:
	return ""


## 绘制橡皮筋预览。p 为当前光标位置（模型坐标）。
func draw_preview(_ci: CanvasItem, _view: ViewTransform, _p: Vector2) -> void:
	pass


## 结束命令（统一出口，便于将来加钩子）
func finish() -> void:
	finished = true


# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------

## 把用户输入文本解析为模型坐标。支持：
##   "100,200"      绝对坐标
##   "@50,0"        相对上一点
##   "@100<30"      相对上一点、极坐标（距离<角度）
##   "100<45"       绝对极坐标
func parse_point(s: String, base: Vector2) -> Dictionary:
	var t := s.strip_edges()
	if t == "":
		return {"ok": false}
	var relative := false
	if t.begins_with("@"):
		relative = true
		t = t.substr(1)
	if t.contains("<"):
		var parts := t.split("<")
		if parts.size() != 2:
			return {"ok": false}
		var dist := parts[0].to_float()
		var ang := deg_to_rad(parts[1].to_float())
		var p := base + Vector2(cos(ang), sin(ang)) * dist
		return {"ok": true, "point": p if relative else Vector2(cos(ang), sin(ang)) * dist}
	var parts2 := t.split(",")
	if parts2.size() != 2:
		# 只给一个数：按正交方向取距离（依赖上一点）
		if t.is_valid_float() and points.size() > 0:
			var d := t.to_float()
			var last := points[points.size() - 1]
			return {"ok": true, "point": last + Vector2(d, 0.0)}
		return {"ok": false}
	var v := Vector2(parts2[0].to_float(), parts2[1].to_float())
	if relative:
		return {"ok": true, "point": base + v}
	return {"ok": true, "point": v}


## 设置一个新图元的公共属性（跟随文档当前设置）
func apply_defaults(e: CadEntity) -> void:
	if ctx == null or ctx.doc == null:
		return
	var doc := ctx.doc
	e.layer = doc.current_layer
	e.aci = doc.current_aci
	e.color = doc.current_color
	e.linetype = doc.current_linetype
	e.lineweight = doc.current_lineweight
