class_name CommandContext
extends RefCounted
## 命令运行所需的上下文。把命令与具体的界面/渲染实现解耦，
## 使命令可以被单元测试直接驱动（无需真实窗口）。

var doc: CadDocument = null
var view: ViewTransform = null
## CadViewport，用于请求重绘与读取界面状态；测试中可为 null
var viewport = null
## 当前选择集（P1 引入）
var selection: Array[CadEntity] = []
## 全局设置（捕捉开关等，P2 引入）
var settings: Dictionary = {}


func request_redraw() -> void:
	if viewport != null and viewport.has_method("queue_redraw"):
		viewport.queue_redraw()


func set_status(msg: String) -> void:
	if viewport != null and viewport.has_method("set_prompt"):
		viewport.set_prompt(msg)
