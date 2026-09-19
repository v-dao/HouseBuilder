class_name CadDocument
extends RefCounted
## 图纸文档。持有全部数据表与图元，是唯一的真相来源。
##
## 变更通知：所有对图元的增删改都必须经过本类的 add_entity / remove_entity /
## mark_modified，这样撤销栈与渲染脏标记才能保持一致。直接改 entities 数组
## 会绕过撤销记录。

signal changed()                       ## 任意内容变化
signal entity_added(e: CadEntity)
signal entity_removed(e: CadEntity)
signal tables_changed()                ## 图层/线型/样式等表变化

# --- 数据表（键为名称）---
var layers: Dictionary = {}
var linetypes: Dictionary = {}
var text_styles: Dictionary = {}
var dim_styles: Dictionary = {}
var blocks: Dictionary = {}

# --- 图元 ---
var entities: Array[CadEntity] = []
## handle -> CadEntity，便于按标识快速查找
var _by_handle: Dictionary = {}
var _next_handle: int = 1

# --- 当前设置（新图元的默认属性，对应界面上的"当前层/当前颜色"）---
var current_layer: String = "0"
var current_color: Color = Color.WHITE
var current_aci: int = 256             ## 256 = 随层
var current_linetype: String = "BYLAYER"
var current_lineweight: float = CadLayer.LW_BYLAYER
var current_text_style: String = "仿宋_3.5"
var current_dim_style: String = "国标-1:100"

# --- 全局设置 ---
## 全局线型比例 (LTSCALE)。
## 国标线型的 pattern 按"图纸上的毫米"定义（如单点长画线一个周期约 30mm），
## 而模型空间是 1:1 的真实毫米（一栋住宅 8000mm 跨），若 LTSCALE=1，
## 一个线型周期在图上不足 1 个像素，虚线/点画线会被渲染器判定为"过密"而退化成实线。
## 国内建筑 CAD 的实际习惯是把 LTSCALE 设在 20~50。这里默认 20。
var ltscale: float = 20.0
## 全局标注比例（出图比例的倒数）
var dimscale: float = 100.0
## 当前出图比例，1:100 记为 100
var plot_scale: float = 100.0
## 图形单位：国标建筑图以毫米为单位
var unit_name: String = "mm"

# --- 撤销 ---
var undo: UndoStack = UndoStack.new()

## 文档自增版本号，渲染器据此判断缓存是否失效
var revision: int = 0


func _init() -> void:
	_init_default_tables()


func _init_default_tables() -> void:
	# 0 层不可删除，这是 DXF 的约定
	layers["0"] = CadLayer.make("0", Color.WHITE, 7, "CONTINUOUS", CadLayer.LW_DEFAULT, "默认层")
	linetypes = CadLinetype.gb_library()
	text_styles = CadTextStyle.gb_library()
	dim_styles = CadDimStyle.gb_library()


# ---------------------------------------------------------------------------
# 图元增删改（全部经由此处，保证撤销与脏标记一致）
# ---------------------------------------------------------------------------

func alloc_handle() -> int:
	var h := _next_handle
	_next_handle += 1
	return h


func add_entity(e: CadEntity, record := true) -> void:
	if e.handle == 0:
		e.handle = alloc_handle()
	elif e.handle >= _next_handle:
		_next_handle = e.handle + 1
	entities.append(e)
	_by_handle[e.handle] = e
	e._attach_document(self)
	if record and undo.is_recording():
		undo.record_add(e)
	_bump()
	entity_added.emit(e)


func add_entities(list: Array, record := true) -> void:
	for e in list:
		add_entity(e, record)


func remove_entity(e: CadEntity, record := true) -> bool:
	var idx := entities.find(e)
	if idx < 0:
		return false
	if record and undo.is_recording():
		undo.record_remove(e)
	entities.remove_at(idx)
	_by_handle.erase(e.handle)
	e._detach_document()
	_bump()
	entity_removed.emit(e)
	return true


func remove_entities(list: Array, record := true) -> void:
	for e in list:
		remove_entity(e, record)


## 在修改图元内容**之前**调用，保存修改前快照
func mark_modified(e: CadEntity) -> void:
	if undo.is_recording():
		undo.record_modify(e)


func mark_modified_list(list: Array) -> void:
	if not undo.is_recording():
		return
	for e in list:
		undo.record_modify(e)


func get_by_handle(h: int) -> CadEntity:
	return _by_handle.get(h)


func entity_count() -> int:
	return entities.size()


## 文档外包盒
func get_bbox() -> Rect2:
	if entities.is_empty():
		return Rect2()
	var bb := entities[0].get_bbox()
	for i in range(1, entities.size()):
		bb = bb.merge(entities[i].get_bbox())
	return bb


## 强制刷新某图元的包围盒（几何被外部改动后调用）
func touch(e: CadEntity) -> void:
	e.invalidate_bbox()
	_bump()


func _bump() -> void:
	revision += 1
	changed.emit()


# ---------------------------------------------------------------------------
# 事务
# ---------------------------------------------------------------------------

func begin_transaction(label: String) -> void:
	undo.begin(label)


## 提交事务。返回是否产生了实际变更。
func commit_transaction() -> bool:
	var changed_any := undo.commit(_by_handle)
	if changed_any:
		_bump()
	return changed_any


## 放弃事务：把已发生的改动逆向还原
func rollback_transaction() -> void:
	var entry := undo.rollback()
	if entry == null:
		return
	# 撤销新增
	for e in entry.added:
		var cur: CadEntity = _by_handle.get(e.handle)
		if cur != null:
			remove_entity(cur, false)
	# 撤销删除
	for e in entry.removed:
		add_entity(e, false)
	# 恢复修改
	for h in entry.before.keys():
		var snapshot: CadEntity = entry.before[h]
		var cur: CadEntity = _by_handle.get(h)
		if cur == null:
			add_entity(snapshot, false)
		else:
			_restore_into(cur, snapshot)
	_bump()


## 用快照内容覆盖现有图元的字段（保持对象标识不变，避免外部持有的引用失效）
func _restore_into(target: CadEntity, snapshot: CadEntity) -> void:
	var d := snapshot.to_dict()
	target.from_dict(d)
	# 专有字段需要子类处理，这里用替换法最稳妥
	var idx := entities.find(target)
	if idx >= 0:
		_by_handle[snapshot.handle] = snapshot
		entities[idx] = snapshot
		snapshot.invalidate_bbox()


func undo_last() -> bool:
	if not undo.can_undo():
		return false
	var e := undo.pop_undo()
	_apply_undo_entry(e)
	return true


func redo_last() -> bool:
	if not undo.can_redo():
		return false
	var e := undo.pop_redo()
	_apply_redo_entry(e)
	return true


func _apply_undo_entry(e: UndoStack.Entry) -> void:
	for ent in e.added:
		var cur: CadEntity = _by_handle.get(ent.handle)
		if cur != null:
			remove_entity(cur, false)
	for ent in e.removed:
		add_entity(ent, false)
	for h in e.before.keys():
		_replace_entity(e.before[h])
	_bump()


func _apply_redo_entry(e: UndoStack.Entry) -> void:
	for ent in e.added:
		if _by_handle.get(ent.handle) == null:
			add_entity(ent, false)
	for ent in e.removed:
		var cur: CadEntity = _by_handle.get(ent.handle)
		if cur != null:
			remove_entity(cur, false)
	for h in e.after.keys():
		_replace_entity(e.after[h])
	_bump()


func _replace_entity(snapshot: CadEntity) -> void:
	var cur: CadEntity = _by_handle.get(snapshot.handle)
	if cur == null:
		add_entity(snapshot, false)
		return
	var idx := entities.find(cur)
	if idx >= 0:
		entities[idx] = snapshot
	_by_handle[snapshot.handle] = snapshot


# ---------------------------------------------------------------------------
# 图层与查表
# ---------------------------------------------------------------------------

func get_layer(name: String) -> CadLayer:
	return layers.get(name)


func ensure_layer(name: String) -> CadLayer:
	var l: CadLayer = layers.get(name)
	if l == null:
		l = CadLayer.make(name, Color.WHITE, 7, "CONTINUOUS", CadLayer.LW_DEFAULT)
		layers[name] = l
		tables_changed.emit()
	return l


func layer_names() -> Array[String]:
	var out: Array[String] = []
	for k in layers.keys():
		out.append(String(k))
	out.sort()
	return out


func get_linetype(name: String) -> CadLinetype:
	return linetypes.get(name)


func get_text_style(name: String) -> CadTextStyle:
	var s: CadTextStyle = text_styles.get(name)
	if s == null:
		# 找不到时回退到第一个可用样式，保证渲染不崩
		for k in text_styles.keys():
			return text_styles[k]
	return s


func get_dim_style(name: String) -> CadDimStyle:
	var s: CadDimStyle = dim_styles.get(name)
	if s == null:
		for k in dim_styles.keys():
			return dim_styles[k]
	return null


func get_block(name: String) -> CadBlock:
	return blocks.get(name)


# ---------------------------------------------------------------------------
# 解析图元的显示属性（随层 / 随块的最终取值）
# ---------------------------------------------------------------------------

## 解析颜色：图元自身未指定时取图层颜色
func resolve_color(e: CadEntity) -> Color:
	if e.aci == 0:
		# 随块：块引用会覆盖，独立图元时退化为随层
		var bl: CadLayer = layers.get(e.layer)
		return bl.color if bl != null else Color.WHITE
	if e.aci == 256 or e.aci < 0:
		var l: CadLayer = layers.get(e.layer)
		return l.color if l != null else Color.WHITE
	return e.color


## 解析线型名
func resolve_linetype(e: CadEntity) -> String:
	if e.linetype == "BYLAYER" or e.linetype == "":
		var l: CadLayer = layers.get(e.layer)
		return l.linetype if l != null else "CONTINUOUS"
	if e.linetype == "BYBLOCK":
		return "CONTINUOUS"
	return e.linetype


## 解析线宽 (mm)。返回负数表示"使用默认线宽"。
func resolve_lineweight(e: CadEntity) -> float:
	if e.lineweight == CadLayer.LW_BYLAYER:
		var l: CadLayer = layers.get(e.layer)
		return l.lineweight if l != null else CadLayer.LW_DEFAULT
	if e.lineweight == CadLayer.LW_BYBLOCK:
		return CadLayer.LW_DEFAULT
	return e.lineweight


func is_layer_visible(name: String) -> bool:
	var l: CadLayer = layers.get(name)
	return l == null or l.is_displayable()
