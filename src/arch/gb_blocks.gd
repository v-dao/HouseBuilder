class_name GbBlocks
extends RefCounted
## 内置建筑图库（1:1 实尺）。
##
## 全部按**真实尺寸（mm）**绘制，插入时不需要缩放，直接放到平面图上即可。
## 每个块带属性定义（编号 / 洞口宽 / 洞口高），供门窗表自动提取。
##
## 命名约定：`M0921` = 门 900 宽 2100 高；`C1515` = 窗 1500 宽 1500 高。
## 这与国内设计院的门窗编号习惯一致。
##
## 块的基点在**左下角**（窗）或**铰链侧**（门），便于对齐轴线或墙边。

## 墙厚（门窗块按 240 厚墙绘制，插入到其他墙厚时整体缩放或用属性改）
const WALL := 240.0
## 门扇厚度
const LEAF := 40.0


## 安装全部内置块到文档。重复调用不会重复安装。
static func install(doc: CadDocument) -> void:
	_install_doors(doc)
	_install_windows(doc)
	_install_sanitary(doc)
	_install_kitchen(doc)
	_install_furniture(doc)
	_install_stairs(doc)


static func block_names() -> Array[String]:
	var out: Array[String] = []
	out.append_array([
		"M0921", "M1021", "M1521", "MTL1821", "MZM1221",
		"C0912", "C1215", "C1515", "C1815", "C2115", "CTL1815", "CPC1815",
		"坐便器", "蹲便器", "洗手盆", "浴缸", "淋浴间",
		"灶台", "水槽", "冰箱",
		"双人床", "单人床", "三人沙发", "餐桌", "衣柜", "电视柜",
		"双跑楼梯",
	])
	return out


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

## 注意：CadBlock.attribute_defs 是 Array[Dictionary]，
## 无类型的 Array 字面量（含 []）不能赋给它，必须用带类型标注的写法。
static func _new_block(doc: CadDocument, name: String, desc: String,
		attrs: Array[Dictionary]) -> CadBlock:
	var b := CadBlock.make(name)
	b.description = desc
	b.builtin = true
	b.attribute_defs = attrs
	doc.blocks[name] = b
	return b


static func _no_attrs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	return out


static func _line(b: CadBlock, layer: String, a: Vector2, c: Vector2) -> void:
	var e := EntLine.make(a, c)
	e.layer = layer
	e.aci = 256
	b.add(e)


static func _rect(b: CadBlock, layer: String, x: float, y: float, w: float, h: float) -> void:
	_line(b, layer, Vector2(x, y), Vector2(x + w, y))
	_line(b, layer, Vector2(x + w, y), Vector2(x + w, y + h))
	_line(b, layer, Vector2(x + w, y + h), Vector2(x, y + h))
	_line(b, layer, Vector2(x, y + h), Vector2(x, y))


static func _arc(b: CadBlock, layer: String, c: Vector2, r: float, a0: float, a1: float) -> void:
	var e := EntArc.make(c, r, a0, a1)
	e.layer = layer
	e.aci = 256
	b.add(e)


static func _poly(b: CadBlock, layer: String, pts: PackedVector2Array, closed := false) -> void:
	var e := EntPolyline.make(pts, PackedFloat64Array(), closed)
	e.layer = layer
	e.aci = 256
	b.add(e)


## 门窗块的通用属性定义
static func _opening_attrs(no: String, w: float, h: float) -> Array[Dictionary]:
	return [
		{"tag": "编号", "default": no, "prompt": "门窗编号"},
		{"tag": "洞口宽", "default": "%.0f" % w, "prompt": "洞口宽度 (mm)"},
		{"tag": "洞口高", "default": "%.0f" % h, "prompt": "洞口高度 (mm)"},
	]


# ---------------------------------------------------------------------------
# 门
# ---------------------------------------------------------------------------

static func _install_doors(doc: CadDocument) -> void:
	# 单扇平开门：铰链在基点，门扇沿 +X，开启弧朝 +Y
	_single_door(doc, "M0921", 900.0, 2100.0, false)
	_single_door(doc, "M1021", 1000.0, 2100.0, false)
	# 双扇平开门
	_double_door(doc, "M1521", 1500.0, 2100.0)
	# 推拉门：两扇叠错
	_sliding_door(doc, "MTL1821", 1800.0, 2100.0)
	# 子母门：一宽一窄
	_unequal_door(doc, "MZM1221", 1200.0, 2100.0)


static func _single_door(doc: CadDocument, name: String, w: float, h: float, flip: bool) -> void:
	var b := _new_block(doc, name, "单扇平开门 %d×%d" % [int(w), int(h)],
		_opening_attrs(name, w, h))
	var sgn := -1.0 if flip else 1.0
	# 门扇（平面图中以细长矩形表示）
	_rect(b, "门窗", 0.0, 0.0, w, LEAF * sgn)
	# 90° 开启弧：自门扇端部转到墙面
	_arc(b, "门窗", Vector2.ZERO, w, 0.0, PI * 0.5 if not flip else -PI * 0.5)
	# 洞口两侧的墙端线（帮助定位，出图时属门窗图层）
	_line(b, "门窗", Vector2(0, 0), Vector2(0, WALL * sgn))
	_line(b, "门窗", Vector2(w, 0), Vector2(w, WALL * sgn))


static func _double_door(doc: CadDocument, name: String, w: float, h: float) -> void:
	var b := _new_block(doc, name, "双扇平开门 %d×%d" % [int(w), int(h)],
		_opening_attrs(name, w, h))
	var half := w * 0.5
	_rect(b, "门窗", 0.0, 0.0, half, LEAF)
	_rect(b, "门窗", half, 0.0, half, LEAF)
	_arc(b, "门窗", Vector2.ZERO, half, 0.0, PI * 0.5)
	_arc(b, "门窗", Vector2(w, 0), half, PI * 0.5, PI)
	_line(b, "门窗", Vector2(0, 0), Vector2(0, WALL))
	_line(b, "门窗", Vector2(w, 0), Vector2(w, WALL))


static func _sliding_door(doc: CadDocument, name: String, w: float, h: float) -> void:
	var b := _new_block(doc, name, "推拉门 %d×%d" % [int(w), int(h)],
		_opening_attrs(name, w, h))
	var half := w * 0.5
	# 两扇错开叠放，各自占洞宽一半
	_rect(b, "门窗", 0.0, 0.0, half + 60.0, LEAF)
	_rect(b, "门窗", half - 60.0, LEAF * 1.6, half + 60.0, LEAF)
	_line(b, "门窗", Vector2(0, 0), Vector2(0, WALL))
	_line(b, "门窗", Vector2(w, 0), Vector2(w, WALL))


static func _unequal_door(doc: CadDocument, name: String, w: float, h: float) -> void:
	var b := _new_block(doc, name, "子母门 %d×%d" % [int(w), int(h)],
		_opening_attrs(name, w, h))
	var main := w * 0.7
	var sub := w - main
	_rect(b, "门窗", 0.0, 0.0, main, LEAF)
	_rect(b, "门窗", main, 0.0, sub, LEAF)
	_arc(b, "门窗", Vector2.ZERO, main, 0.0, PI * 0.5)
	_arc(b, "门窗", Vector2(w, 0), sub, PI * 0.5, PI)
	_line(b, "门窗", Vector2(0, 0), Vector2(0, WALL))
	_line(b, "门窗", Vector2(w, 0), Vector2(w, WALL))


# ---------------------------------------------------------------------------
# 窗
# ---------------------------------------------------------------------------

static func _install_windows(doc: CadDocument) -> void:
	# 平开窗（四条平行线：窗框两道 + 玻璃两道）
	_plain_window(doc, "C0912", 900.0, 1200.0)
	_plain_window(doc, "C1215", 1200.0, 1500.0)
	_plain_window(doc, "C1515", 1500.0, 1500.0)
	_plain_window(doc, "C1815", 1800.0, 1500.0)
	_plain_window(doc, "C2115", 2100.0, 1500.0)
	# 推拉窗
	_sliding_window(doc, "CTL1815", 1800.0, 1500.0)
	# 飘窗：窗台外挑
	_bay_window(doc, "CPC1815", 1800.0, 1500.0)


## 平开窗：在墙厚范围内画四条平行线（窗框 2 + 玻璃 2）
static func _plain_window(doc: CadDocument, name: String, w: float, h: float) -> void:
	var b := _new_block(doc, name, "平开窗 %d×%d" % [int(w), int(h)],
		_opening_attrs(name, w, h))
	var inset := WALL * 0.18
	for y in [0.0, inset, WALL - inset, WALL]:
		_line(b, "门窗", Vector2(0.0, y), Vector2(w, y))


static func _sliding_window(doc: CadDocument, name: String, w: float, h: float) -> void:
	var b := _new_block(doc, name, "推拉窗 %d×%d" % [int(w), int(h)],
		_opening_attrs(name, w, h))
	var half := w * 0.5
	# 两条窗框线 + 中间两条错开的窗扇线
	_line(b, "门窗", Vector2(0.0, 0.0), Vector2(w, 0.0))
	_line(b, "门窗", Vector2(0.0, WALL), Vector2(w, WALL))
	_line(b, "门窗", Vector2(0.0, WALL * 0.35), Vector2(half + 40.0, WALL * 0.35))
	_line(b, "门窗", Vector2(half - 40.0, WALL * 0.65), Vector2(w, WALL * 0.65))


## 飘窗：窗台向室外外挑 500，三面为窗
static func _bay_window(doc: CadDocument, name: String, w: float, h: float) -> void:
	var b := _new_block(doc, name, "飘窗 %d×%d（外挑 500）" % [int(w), int(h)],
		_opening_attrs(name, w, h))
	var out := 500.0
	# 室内侧窗
	_line(b, "门窗", Vector2(0.0, 0.0), Vector2(w, 0.0))
	# 外挑的窗台板
	_line(b, "门窗", Vector2(0.0, 0.0), Vector2(-out, -WALL - out))
	_line(b, "门窗", Vector2(w, 0.0), Vector2(w + out, -WALL - out))
	_line(b, "门窗", Vector2(-out, -WALL - out), Vector2(w + out, -WALL - out))
	# 三面玻璃线
	_line(b, "门窗", Vector2(-out + 60.0, -WALL - out + 60.0),
		Vector2(w + out - 60.0, -WALL - out + 60.0))


# ---------------------------------------------------------------------------
# 卫生洁具
# ---------------------------------------------------------------------------

static func _install_sanitary(doc: CadDocument) -> void:
	# 坐便器 700×400（含水箱）
	var b := _new_block(doc, "坐便器", "坐便器 700×400", _no_attrs())
	_rect(b, "设备", 0.0, 0.0, 700.0, 400.0)
	_rect(b, "设备", 0.0, 80.0, 180.0, 240.0)          # 水箱
	_poly(b, "设备", PackedVector2Array([
		Vector2(220.0, 60.0), Vector2(560.0, 20.0), Vector2(660.0, 200.0),
		Vector2(560.0, 380.0), Vector2(220.0, 340.0)]), true)  # 便体

	# 蹲便器 900×450（含踏步）
	b = _new_block(doc, "蹲便器", "蹲便器 900×450", _no_attrs())
	_rect(b, "设备", 0.0, 0.0, 900.0, 450.0)
	_rect(b, "设备", 250.0, 110.0, 400.0, 230.0)
	_arc(b, "设备", Vector2(450.0, 225.0), 90.0, 0.0, TAU)

	# 洗手盆 600×450
	b = _new_block(doc, "洗手盆", "洗手盆 600×450", _no_attrs())
	_poly(b, "设备", PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(600.0, 0.0), Vector2(560.0, 360.0),
		Vector2(40.0, 360.0)]), true)
	_poly(b, "设备", PackedVector2Array([
		Vector2(80.0, 60.0), Vector2(520.0, 60.0), Vector2(490.0, 320.0),
		Vector2(110.0, 320.0)]), true)
	_arc(b, "设备", Vector2(300.0, 190.0), 30.0, 0.0, TAU)  # 落水口

	# 浴缸 1700×750
	b = _new_block(doc, "浴缸", "浴缸 1700×750", _no_attrs())
	_rect(b, "设备", 0.0, 0.0, 1700.0, 750.0)
	_poly(b, "设备", PackedVector2Array([
		Vector2(80.0, 80.0), Vector2(1620.0, 80.0), Vector2(1620.0, 670.0),
		Vector2(80.0, 670.0)]), true)
	_arc(b, "设备", Vector2(1400.0, 375.0), 35.0, 0.0, TAU)

	# 淋浴间 900×900
	b = _new_block(doc, "淋浴间", "淋浴间 900×900", _no_attrs())
	_rect(b, "设备", 0.0, 0.0, 900.0, 900.0)
	_line(b, "设备", Vector2(0.0, 0.0), Vector2(900.0, 900.0))
	_arc(b, "设备", Vector2(150.0, 150.0), 40.0, 0.0, TAU)


# ---------------------------------------------------------------------------
# 厨房设备
# ---------------------------------------------------------------------------

static func _install_kitchen(doc: CadDocument) -> void:
	# 灶台 600 深
	var b := _new_block(doc, "灶台", "灶台 600 深（双眼灶）", _no_attrs())
	_rect(b, "设备", 0.0, 0.0, 1200.0, 600.0)
	_arc(b, "设备", Vector2(320.0, 300.0), 140.0, 0.0, TAU)
	_arc(b, "设备", Vector2(880.0, 300.0), 140.0, 0.0, TAU)

	# 水槽 800×500
	b = _new_block(doc, "水槽", "水槽 800×500（双槽）", _no_attrs())
	_rect(b, "设备", 0.0, 0.0, 800.0, 500.0)
	_rect(b, "设备", 60.0, 70.0, 320.0, 360.0)
	_rect(b, "设备", 420.0, 70.0, 320.0, 360.0)

	# 冰箱 650×650
	b = _new_block(doc, "冰箱", "冰箱 650×650", _no_attrs())
	_rect(b, "设备", 0.0, 0.0, 650.0, 650.0)
	_line(b, "设备", Vector2(0.0, 520.0), Vector2(650.0, 520.0))


# ---------------------------------------------------------------------------
# 家具
# ---------------------------------------------------------------------------

static func _install_furniture(doc: CadDocument) -> void:
	# 双人床 1800×2000（含床头柜位）
	var b := _new_block(doc, "双人床", "双人床 1800×2000", _no_attrs())
	_rect(b, "家具", 0.0, 0.0, 1800.0, 2000.0)
	_rect(b, "家具", 0.0, 1700.0, 1800.0, 300.0)      # 床头
	_line(b, "家具", Vector2(900.0, 0.0), Vector2(900.0, 1700.0))

	# 单人床 1000×2000
	b = _new_block(doc, "单人床", "单人床 1000×2000", _no_attrs())
	_rect(b, "家具", 0.0, 0.0, 1000.0, 2000.0)
	_rect(b, "家具", 0.0, 1700.0, 1000.0, 300.0)

	# 三人沙发 2000×850
	b = _new_block(doc, "三人沙发", "三人沙发 2000×850", _no_attrs())
	_rect(b, "家具", 0.0, 0.0, 2000.0, 850.0)
	_rect(b, "家具", 0.0, 600.0, 2000.0, 250.0)       # 靠背
	_rect(b, "家具", 0.0, 0.0, 180.0, 600.0)           # 扶手
	_rect(b, "家具", 1820.0, 0.0, 180.0, 600.0)
	_line(b, "家具", Vector2(667.0, 0.0), Vector2(667.0, 600.0))
	_line(b, "家具", Vector2(1333.0, 0.0), Vector2(1333.0, 600.0))

	# 餐桌 1400×800（四人位）
	b = _new_block(doc, "餐桌", "餐桌 1400×800（四椅）", _no_attrs())
	_rect(b, "家具", 0.0, 0.0, 1400.0, 800.0)
	_rect(b, "家具", -420.0, 180.0, 380.0, 440.0)
	_rect(b, "家具", 1440.0, 180.0, 380.0, 440.0)
	_rect(b, "家具", 480.0, -420.0, 440.0, 380.0)
	_rect(b, "家具", 480.0, 840.0, 440.0, 380.0)

	# 衣柜 1800×600
	b = _new_block(doc, "衣柜", "衣柜 1800×600", _no_attrs())
	_rect(b, "家具", 0.0, 0.0, 1800.0, 600.0)
	for i in range(1, 3):
		var x := 600.0 * float(i)
		_line(b, "家具", Vector2(x, 0.0), Vector2(x, 600.0))
	# 挂衣杆示意
	_line(b, "家具", Vector2(60.0, 480.0), Vector2(1740.0, 480.0))

	# 电视柜 1800×450
	b = _new_block(doc, "电视柜", "电视柜 1800×450", _no_attrs())
	_rect(b, "家具", 0.0, 0.0, 1800.0, 450.0)
	_rect(b, "家具", 550.0, 60.0, 700.0, 180.0)


# ---------------------------------------------------------------------------
# 楼梯
# ---------------------------------------------------------------------------

## 双跑楼梯块（示意用；参数化楼梯命令在建筑工具阶段提供）
## 踏步 280×9 级、梯段宽 1100、平台 1100，洞口 2400×4800
static func _install_stairs(doc: CadDocument) -> void:
	var b := _new_block(doc, "双跑楼梯", "双跑楼梯（踏步 280，9 级，梯段宽 1100）", _no_attrs())
	var tread := 280.0
	var steps := 9
	var flight_w := 1100.0
	var landing := 1100.0
	var well := 200.0
	var total_w := flight_w * 2.0 + well
	var flight_h := tread * float(steps)
	# 外轮廓
	_rect(b, "楼梯", 0.0, 0.0, total_w, flight_h + landing)
	# 两跑踏步线
	for i in range(steps):
		var y := landing + tread * float(i)
		_line(b, "楼梯", Vector2(0.0, y), Vector2(flight_w, y))
		_line(b, "楼梯", Vector2(flight_w + well, y), Vector2(total_w, y))
	# 中间休息平台
	_line(b, "楼梯", Vector2(0.0, landing), Vector2(total_w, landing))
	# 梯井
	_line(b, "楼梯", Vector2(flight_w, landing), Vector2(flight_w, flight_h + landing))
	_line(b, "楼梯", Vector2(flight_w + well, landing), Vector2(flight_w + well, flight_h + landing))
	# 上行箭头
	_line(b, "楼梯", Vector2(flight_w * 0.5, landing + 120.0), Vector2(flight_w * 0.5, flight_h + landing - 120.0))
	var ay := flight_h + landing - 120.0
	_line(b, "楼梯", Vector2(flight_w * 0.5, ay), Vector2(flight_w * 0.5 - 90.0, ay - 160.0))
	_line(b, "楼梯", Vector2(flight_w * 0.5, ay), Vector2(flight_w * 0.5 + 90.0, ay - 160.0))
