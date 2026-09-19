class_name UndoStack
extends RefCounted
## 基于操作记录的撤销栈。
##
## 早期版本考虑过"整文档快照"，但对十万级图元的图纸来说内存与耗时都不可接受。
## 这里改为记录**操作的净效果**：新增了哪些图元、删除了哪些图元、
## 修改了哪些图元（保存修改前后的副本）。撤销即反向应用，重做即正向应用。
##
## 用法（由 CadDocument 封装，命令代码通常不直接接触本类）：
##   doc.begin_transaction("画直线")
##   doc.add_entity(line)
##   doc.commit_transaction()
## 中途放弃用 doc.rollback_transaction()。

class Entry:
	extends RefCounted
	var label: String = ""
	## 事务新增的图元（撤销时按 handle 删除）
	var added: Array[CadEntity] = []
	## 事务删除的图元（撤销时原样加回）
	var removed: Array[CadEntity] = []
	## 事务修改的图元：handle -> 修改前的克隆
	var before: Dictionary = {}
	## 事务修改的图元：handle -> 修改后的克隆（重做时恢复）
	var after: Dictionary = {}

	func is_empty() -> bool:
		return added.is_empty() and removed.is_empty() and before.is_empty()


var _undo: Array[Entry] = []
var _redo: Array[Entry] = []
var _active: Entry = null
var _max_depth: int = 200


func set_max_depth(n: int) -> void:
	_max_depth = maxi(n, 1)
	_trim()


## 是否有事务正在进行
func is_recording() -> bool:
	return _active != null


func begin(label: String) -> void:
	if _active != null:
		push_error("UndoStack: 上一个事务尚未提交，label=%s" % _active.label)
		return
	_active = Entry.new()
	_active.label = label


## 记录新增
func record_add(e: CadEntity) -> void:
	if _active != null:
		_active.added.append(e)


## 记录删除
func record_remove(e: CadEntity) -> void:
	if _active != null:
		_active.removed.append(e)


## 记录修改前的状态（同一事务内同一图元只记一次）
func record_modify(e: CadEntity) -> void:
	if _active == null:
		return
	if _active.before.has(e.handle):
		return
	_active.before[e.handle] = e.clone()


## 事务提交时登记修改后的状态
func _finalize_after(entities_by_handle: Dictionary) -> void:
	if _active == null:
		return
	for h in _active.before.keys():
		var e: CadEntity = entities_by_handle.get(h)
		_active.after[h] = e.clone() if e != null else _active.before[h].clone()


## 提交事务。返回是否产生了实际变更。
func commit(entities_by_handle: Dictionary) -> bool:
	if _active == null:
		return false
	_finalize_after(entities_by_handle)
	if _active.is_empty():
		_active = null
		return false
	_undo.append(_active)
	_active = null
	_redo.clear()
	_trim()
	return true


## 放弃事务，返回需要清理的信息：撤销时把新增的删掉、把删除的加回、
## 把已修改的恢复。调用方（CadDocument）负责实际执行。
func rollback() -> Entry:
	var e := _active
	_active = null
	return e


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo_label() -> String:
	return _undo[-1].label if not _undo.is_empty() else ""


func redo_label() -> String:
	return _redo[-1].label if not _redo.is_empty() else ""


## 弹出待撤销的事务
func pop_undo() -> Entry:
	if _undo.is_empty():
		return null
	var e: Entry = _undo.pop_back()
	_redo.append(e)
	return e


## 弹出待重做的事务
func pop_redo() -> Entry:
	if _redo.is_empty():
		return null
	var e: Entry = _redo.pop_back()
	_undo.append(e)
	return e


func clear() -> void:
	_undo.clear()
	_redo.clear()
	_active = null


func undo_count() -> int:
	return _undo.size()


func _trim() -> void:
	while _undo.size() > _max_depth:
		_undo.pop_front()
