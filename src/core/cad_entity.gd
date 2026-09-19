class_name CadEntity
extends RefCounted
## 所有图元的基类。
##
## 设计要点：图元是**纯数据对象**（RefCounted），不挂到场景树上。
## 渲染只是它的一种投影。这样做的原因：
##   1. DXF 读写需要按实体类型映射字段，与节点无关
##   2. 撤销栈用快照（clone）实现，不需要节点生命周期管理
##   3. 后续里程碑（自动生成 3D 墙体/楼板、排砖、钢筋、工程量统计）
##      都是同一份数据的另一批消费者，无需重构
##
## 坐标约定：图元直接存储**世界坐标**（模型空间，mm，Y 轴向上）。
## 只有块引用（EntInsert）带自身变换。

## 图元类型。数值不影响外部格式，DXF 映射在 io/dxf_writer 中单独处理。
enum Type {
	LINE,
	POLYLINE,
	CIRCLE,
	ARC,
	ELLIPSE,
	SPLINE,
	POINT,
	TEXT,
	MTEXT,
	HATCH,
	DIMENSION,
	LEADER,
	INSERT,
	SOLID,
	XLINE,
	RAY,
	SYMBOL,
	WALL,
}

## 图元所属空间
enum Space { MODEL, PAPER }

# --- 通用属性（全部对应 DXF 实体公共组码）---
var type: int = -1
## 唯一标识，由 CadDocument 分配
var handle: int = 0
var layer: String = "0"
## 颜色。aci == 256 表示随层，aci == 0 表示随块
var color: Color = Color.WHITE
var aci: int = 256
## 线型名。"BYLAYER" / "BYBLOCK" 或具体线型名
var linetype: String = "BYLAYER"
## 线宽 (mm)，负值为哨兵（随层/随块/默认）
var lineweight: float = CadLayer.LW_BYLAYER
## 线型比例（相对全局 LTSCALE）
var linetype_scale: float = 1.0
var visible: bool = true
var space: int = Space.MODEL
## 所属块名（仅当图元位于块定义内时非空）
var owner_block: String = ""

# --- 缓存 ---
var _bbox_cache: Rect2 = Rect2()
var _bbox_valid: bool = false

## 所属文档的弱引用。
## 必须用 WeakRef：文档强引用图元、图元若再强引用文档会形成引用环，
## GDScript 的引用计数无法回收，整张图纸会泄漏。
var _doc_ref: WeakRef = null


## 所属文档，未加入文档时返回 null
func get_document() -> CadDocument:
	return _doc_ref.get_ref() if _doc_ref != null else null


func _attach_document(doc: CadDocument) -> void:
	_doc_ref = weakref(doc)
	invalidate_bbox()


func _detach_document() -> void:
	_doc_ref = null


## 出图比例（1:100 返回 100）。
## 国标里符号与标注的尺寸都以「图纸上的毫米」给出，
## 因此凡是要画到模型空间的符号元素，都必须乘这个比例。
## 脱离文档时按 1:100 处理，便于单元测试。
func plot_scale() -> float:
	var d := get_document()
	return d.plot_scale if d != null else 100.0


# ---------------------------------------------------------------------------
# 子类必须实现
# ---------------------------------------------------------------------------

## 返回图元的解析曲线（世界坐标）。这是几何内核的统一入口。
func get_curves() -> Array[GeoCurve]:
	return []


## 夹点位置（世界坐标）
func get_grips() -> PackedVector2Array:
	return PackedVector2Array()


## STRETCH 用的"可拉伸定义点"。
## 与夹点的区别：夹点含中点等辅助点，而拉伸只应移动真正的定义点
## （例如直线的两个端点、多段线的各个顶点）。
## 默认与夹点一致，图元按需覆写。
func get_stretch_points() -> PackedVector2Array:
	return get_grips()


## 移动第 i 个可拉伸定义点
func move_stretch_point(index: int, pos: Vector2) -> void:
	move_grip(index, pos)


## 拖动第 i 个夹点到新位置
func move_grip(_index: int, _pos: Vector2) -> void:
	pass


## 施加仿射变换（就地修改）
func transform_by(_xf: Transform2D) -> void:
	pass


## 深拷贝
func clone() -> CadEntity:
	return null


## 打散为更基本的图元。返回空数组表示不可打散。
func explode() -> Array[CadEntity]:
	return []


## 类型名（用于界面显示与 DXF 映射）
func type_name() -> String:
	return "未知"


# ---------------------------------------------------------------------------
# 通用实现
# ---------------------------------------------------------------------------

## 包围盒（带缓存）
func get_bbox() -> Rect2:
	if _bbox_valid:
		return _bbox_cache
	var curves := get_curves()
	if curves.is_empty():
		_bbox_cache = Rect2()
	else:
		var bb := curves[0].bbox()
		for i in range(1, curves.size()):
			bb = bb.merge(curves[i].bbox())
		_bbox_cache = bb
	_bbox_valid = true
	return _bbox_cache


func invalidate_bbox() -> void:
	_bbox_valid = false


## 把公共字段复制到另一个图元。clone() 的标准做法是
## 「新建 -> 复制专有字段 -> _copy_base_to」，避免逐个手抄公共字段出错。
func _copy_base_to(other: CadEntity) -> void:
	other.handle = handle
	other.layer = layer
	other.color = color
	other.aci = aci
	other.linetype = linetype
	other.lineweight = lineweight
	other.linetype_scale = linetype_scale
	other.visible = visible
	other.space = space
	other.owner_block = owner_block
	other.invalidate_bbox()


## 到图元的最短距离（用于拾取）
func distance_to(p: Vector2) -> float:
	var best := INF
	for c in get_curves():
		best = minf(best, c.distance_to(p))
	return best


## 需要渲染的文字注记。返回字典数组，每项：
##   { text, position, rotation, height, style, h_align, v_align }
## 默认无。文字图元与尺寸标注通过它把文字交给统一的文字渲染路径，
## 避免渲染器为每种带文字的图元各开一个分支。
func get_annotation_texts() -> Array:
	return []


## 曲线的特征点汇总（供对象捕捉使用）
func feature_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for c in get_curves():
		for f in c.feature_points():
			out.append(f)
	return out


## 图元是否落在给定矩形内（窗选：完全在内）
func is_inside_rect(r: Rect2) -> bool:
	return r.encloses(get_bbox())


## 图元是否与给定矩形相交（交叉选）
func is_crossing_rect(r: Rect2) -> bool:
	var bb := get_bbox()
	if not bb.intersects(r):
		return false
	if r.encloses(bb):
		return true
	for c in get_curves():
		if _curve_crosses_rect(c, r):
			return true
	return false


func _curve_crosses_rect(c: GeoCurve, r: Rect2) -> bool:
	var pts := c.tessellate(maxf(minf(r.size.x, r.size.y) * 0.02, 0.5))
	for p in pts:
		if r.has_point(p):
			return true
	# 曲线段穿越矩形但顶点都不在矩形内的情况：用四条边求交
	var corners := [
		r.position,
		r.position + Vector2(r.size.x, 0),
		r.position + r.size,
		r.position + Vector2(0, r.size.y),
	]
	for i in range(4):
		var e := GeoSeg.make(corners[i], corners[(i + 1) % 4])
		if c.kind() == GeoCurve.Kind.SEG:
			if (c as GeoSeg).intersect_seg(e)["hit"]:
				return true
		elif c.kind() == GeoCurve.Kind.ARC:
			if not (c as GeoArc).intersect_seg(e).is_empty():
				return true
	return false


# ---------------------------------------------------------------------------
# 序列化
# ---------------------------------------------------------------------------

## 公共字段。子类覆写时应先调用 super.to_dict() 再补充专有字段。
func to_dict() -> Dictionary:
	var d := {
		"type": type,
		"handle": handle,
		"layer": layer,
		"aci": aci,
		"linetype": linetype,
		"lineweight": lineweight,
		"linetype_scale": linetype_scale,
		"visible": visible,
		"space": space,
	}
	if aci == 0 or (aci >= 1 and aci <= 255 and aci != 256):
		d["color"] = color.to_html(false)
	if owner_block != "":
		d["owner_block"] = owner_block
	return d


## 从字典恢复公共字段。
## 注意：这里刻意不叫 from_dict —— 子类用 static func from_dict() 做构造工厂，
## 同名会与基类的实例方法冲突（Godot 报 "function signature doesn't match the parent"）。
func read_base_fields(d: Dictionary) -> void:
	handle = int(d.get("handle", 0))
	layer = String(d.get("layer", "0"))
	aci = int(d.get("aci", 256))
	linetype = String(d.get("linetype", "BYLAYER"))
	lineweight = float(d.get("lineweight", CadLayer.LW_BYLAYER))
	linetype_scale = float(d.get("linetype_scale", 1.0))
	visible = bool(d.get("visible", true))
	space = int(d.get("space", Space.MODEL))
	owner_block = String(d.get("owner_block", ""))
	if d.has("color"):
		color = Color.html(String(d["color"]))
	invalidate_bbox()


static func _v2(d: Dictionary, key: String) -> Vector2:
	if not d.has(key):
		return Vector2.ZERO
	var a: Array = d[key]
	return Vector2(float(a[0]), float(a[1]))


static func _put_v2(d: Dictionary, key: String, v: Vector2) -> void:
	# 坐标保留 6 位小数：模型单位为 mm，1e-6mm 远小于任何制图精度
	d[key] = [snappedf(v.x, 0.000001), snappedf(v.y, 0.000001)]


static func _pts_to_arr(pts: PackedVector2Array) -> Array:
	var a := []
	a.resize(pts.size())
	for i in range(pts.size()):
		a[i] = [snappedf(pts[i].x, 0.000001), snappedf(pts[i].y, 0.000001)]
	return a


static func _arr_to_pts(a: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(a.size())
	for i in range(a.size()):
		var e: Array = a[i]
		pts[i] = Vector2(float(e[0]), float(e[1]))
	return pts
