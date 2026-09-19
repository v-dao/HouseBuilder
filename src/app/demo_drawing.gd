class_name DemoDrawing
extends RefCounted
## 示例图纸生成器。
##
## 这张图完全由**参数化建筑工具**生成，而不是手画线段：
##   轴网用 AxisGrid（自动编号 + 两道尺寸）
##   墙体用 EntWall（中心线 + 厚度 + 洞口，墙线随洞口自动断开）
##   门窗是墙体洞口 + 图库块引用
##   房间面积由墙体轮廓做布尔运算算出
## 因此它同时是建筑工具的端到端验收素材。


## 轴距（mm）：两跨 3600 / 4200，两进深 3000 / 3000
const X_SPANS: Array = [3600.0, 4200.0]
const Y_SPANS: Array = [3000.0, 3000.0]
const WALL_OUT := 240.0
const WALL_IN := 120.0


static func build(doc: CadDocument) -> void:
	_setup_layers(doc)

	var xs := AxisGrid.positions_from_spans(X_SPANS)
	var ys := AxisGrid.positions_from_spans(Y_SPANS)
	AxisGrid.build(doc, xs, ys, Vector2.ZERO, 900.0, 1200.0, true)
	var tx := 0.0
	for s in X_SPANS:
		tx += float(s)
	var ty := 0.0
	for s in Y_SPANS:
		ty += float(s)

	# --- 外墙：闭合墙体，中心线落在轴线上 ---
	var ring := EntWall.make(PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(tx, 0.0),
		Vector2(tx, ty),
		Vector2(0.0, ty),
	]), WALL_OUT, true)
	_put(ring, "墙体")
	doc.add_entity(ring, false)
	# 洞口按沿中心线的弧长定位。闭合环自 (0,0) 逆时针起算：
	#   下边 0~tx，右边 tx~tx+ty，上边 tx+ty~2tx+ty，左边 2tx+ty~2tx+2ty
	ring.add_opening(1800.0, 900.0, "M0921", false)                    # 入口门
	ring.add_opening(6000.0, 1500.0, "C1515", true)                    # 下边窗
	ring.add_opening(tx + 3000.0, 1200.0, "C1215", true)               # 右边窗
	ring.add_opening(tx * 2.0 + ty - 1800.0, 1800.0, "C1815", true)    # 上边窗
	ring.add_opening(tx * 2.0 + ty * 2.0 - 3000.0, 1200.0, "C1215", true)  # 左边窗

	# --- 内墙：横向分隔（客厅 / 厨房 / 卫生间）---
	var part_h := EntWall.make(PackedVector2Array([
		Vector2(0.0, 3000.0), Vector2(tx, 3000.0)]), WALL_IN, false)
	_put(part_h, "墙体")
	doc.add_entity(part_h, false)
	part_h.add_opening(1800.0, 900.0, "M0921", false)
	part_h.add_opening(5400.0, 900.0, "M0921", false)

	# --- 内墙：纵向分隔（贯通全高，把上下两层各分成两间）---
	var part_v := EntWall.make(PackedVector2Array([
		Vector2(3600.0, 0.0), Vector2(3600.0, ty)]), WALL_IN, false)
	_put(part_v, "墙体")
	doc.add_entity(part_v, false)
	part_v.add_opening(1500.0, 900.0, "M0921", false)   # 客厅 -> 餐厅
	part_v.add_opening(4500.0, 900.0, "M0921", false)   # 厨房 -> 卫生间

	# --- 门窗块：让门扇与开启弧显示出来 ---
	for w: EntWall in [ring, part_h, part_v]:
		for o in w.opening_inserts():
			var ins := o as EntInsert
			var blk := doc.get_block(ins.block_name)
			if blk != null:
				for a in blk.attribute_defs:
					var ad: Dictionary = a
					ins.attributes[String(ad.get("tag", ""))] = String(ad.get("default", ""))
			ins.layer = "门窗"
			ins.aci = 256
			doc.add_entity(ins, false)

	# --- 房间：面积由墙体轮廓的布尔运算算出，精确到墙体内表面 ---
	_add_room(doc, Vector2(1800.0, 1500.0), "客厅")
	_add_room(doc, Vector2(1800.0, 4500.0), "厨房")
	_add_room(doc, Vector2(5700.0, 4500.0), "卫生间")
	_add_room(doc, Vector2(5700.0, 1500.0), "餐厅")

	# --- 楼梯：参数化插入（放在图面左侧做展示）---
	var stair := EntInsert.make("双跑楼梯", Vector2(-4600.0, 2400.0))
	stair.layer = "楼梯"
	stair.aci = 256
	doc.add_entity(stair, false)

	# --- 门窗表 ---
	_add_schedule(doc, Vector2(-7000.0, 1600.0))

	# --- 国标符号示例 ---
	_add_symbols(doc)

	# --- 材料图例展示条 ---
	_add_hatch_legend(doc)

	# --- 图名与说明 ---
	var title := EntText.make(Vector2(tx * 0.5, -4200.0), "一层平面图  1:100", 700.0)
	title.text_style = "图名_7"
	title.h_align = EntText.HAlign.CENTER
	_put(title, "文字")
	doc.add_entity(title, false)

	var note := EntText.make(Vector2(tx * 0.5, -5100.0),
		"±0.000  室内地坪   外墙 240 厚烧结普通砖   门窗洞口尺寸详见门窗表", 350.0)
	note.text_style = "仿宋_3.5"
	note.h_align = EntText.HAlign.CENTER
	_put(note, "文字")
	doc.add_entity(note, false)


# ---------------------------------------------------------------------------
# 图层
# ---------------------------------------------------------------------------

const LAYER_COLORS := {
	"轴线": [Color(0.55, 0.62, 0.72), 8],
	"墙体": [Color(0.95, 0.95, 0.92), 7],
	"柱": [Color(1.0, 0.85, 0.75), 30],
	"门窗": [Color(0.55, 0.80, 1.0), 4],
	"楼梯": [Color(0.60, 0.85, 0.75), 3],
	"尺寸标注": [Color(1.0, 0.82, 0.35), 2],
	"图例填充": [Color(0.45, 0.48, 0.55), 8],
	"家具": [Color(0.70, 0.62, 0.85), 6],
	"文字": [Color(0.85, 0.95, 0.85), 3],
	"图框": [Color(0.80, 0.80, 0.85), 7],
	"设备": [Color(0.75, 0.78, 0.88), 9],
}


## 按 GB/T 50001 的线宽组建立图层：b / 0.7b / 0.5b / 0.25b
static func _setup_layers(doc: CadDocument) -> void:
	var b := GbLineweight.b_for_plot_scale(doc.plot_scale)
	for row in GbLineweight.default_layer_map():
		var name := String(row[0])
		var linetype := String(row[1])
		var usage := String(row[2])
		var desc := String(row[3])
		var entry = LAYER_COLORS.get(name)
		var color: Color = entry[0] if entry != null else Color.WHITE
		var aci: int = int(entry[1]) if entry != null else 7
		var w := GbLineweight.width_for(usage, b)
		doc.layers[name] = CadLayer.make(name, color, aci, linetype, w, desc)
	# 设备层（洁具、厨具）单独补上，图例映射表里没有
	doc.ensure_layer("设备")


static func _put(e: CadEntity, layer: String) -> void:
	e.layer = layer
	e.aci = 256
	e.linetype = "BYLAYER"
	e.lineweight = CadLayer.LW_BYLAYER


# ---------------------------------------------------------------------------
# 房间与门窗表
# ---------------------------------------------------------------------------

static func _add_room(doc: CadDocument, p: Vector2, name: String) -> void:
	var region := CmdArch.RoomCmd.room_polygon_at(doc, p)
	if region.size() < 3:
		return
	var area := absf(CmdArch.RoomCmd._shoelace(region)) / 1000000.0
	var c := CmdArch.RoomCmd._centroid(region)
	var t := EntText.make(c + Vector2(0.0, 160.0), name, 500.0)
	t.text_style = "房间名_5"
	t.h_align = EntText.HAlign.CENTER
	_put(t, "文字")
	doc.add_entity(t, false)
	var t2 := EntText.make(c - Vector2(0.0, 420.0), "%.1f m²" % area, 320.0)
	t2.text_style = "标注_2.5"
	t2.h_align = EntText.HAlign.CENTER
	_put(t2, "文字")
	doc.add_entity(t2, false)


## 门窗表：从墙体洞口汇总
static func _add_schedule(doc: CadDocument, origin: Vector2) -> void:
	var stats := CmdArch.ScheduleCmd.collect(doc)
	if stats.is_empty():
		return
	var keys: Array[String] = []
	for k in stats.keys():
		keys.append(String(k))
	keys.sort()
	var row_h := 700.0
	var cols := [2000.0, 1200.0, 1200.0, 1000.0, 1600.0]
	var total_w := 0.0
	for c in cols:
		total_w += float(c)
	var rows := keys.size()
	var total_h := row_h * float(rows + 2)
	for i in range(rows + 3):
		var y := origin.y - float(i) * row_h
		_log_line(doc, Vector2(origin.x, y), Vector2(origin.x + total_w, y))
	var x := origin.x
	_log_line(doc, Vector2(x, origin.y), Vector2(x, origin.y - total_h))
	for c in cols:
		x += float(c)
		_log_line(doc, Vector2(x, origin.y), Vector2(x, origin.y - total_h))
	_center_text(doc, Vector2(origin.x + total_w * 0.5, origin.y + row_h * 0.55), "门窗表", 450.0)
	var headers := ["门窗编号", "洞口宽", "洞口高", "数量", "类型"]
	x = origin.x
	for i in range(headers.size()):
		_center_text(doc, Vector2(x + float(cols[i]) * 0.5, origin.y - row_h * 0.5), headers[i], 300.0)
		x += float(cols[i])
	for r in range(rows):
		var k := keys[r]
		var st: Dictionary = stats[k]
		var h := 0.0
		if k.length() >= 5:
			h = float(k.substr(3, 2).to_int()) * 100.0
		var y := origin.y - row_h * float(r + 1) - row_h * 0.5
		var vals := [k, "%.0f" % float(st["width"]), "%.0f" % h,
			str(int(st["count"])), "窗" if bool(st["window"]) else "门"]
		x = origin.x
		for i in range(vals.size()):
			_center_text(doc, Vector2(x + float(cols[i]) * 0.5, y), vals[i], 280.0)
			x += float(cols[i])


static func _log_line(doc: CadDocument, a: Vector2, b: Vector2) -> void:
	var e := EntLine.make(a, b)
	_put(e, "尺寸标注")
	e.lineweight = 0.5
	doc.add_entity(e, false)


static func _center_text(doc: CadDocument, pos: Vector2, s: String, h: float) -> void:
	var t := EntText.make(pos, s, h)
	t.text_style = "仿宋_3.5"
	t.h_align = EntText.HAlign.CENTER
	t.v_align = EntText.VAlign.MIDDLE
	_put(t, "文字")
	doc.add_entity(t, false)


# ---------------------------------------------------------------------------
# 国标符号示例
# ---------------------------------------------------------------------------

## 七种国标符号的示例，集中在图面左下方，便于一眼核对画法
static func _add_symbols(doc: CadDocument) -> void:
	var base := Vector2(-7000.0, 5600.0)
	for pair in [[Vector2(0, 0), 0.0], [Vector2(2200, 0), -1500.0]]:
		var off: Vector2 = pair[0]
		var el := EntSymbols.Elevation.make(base + off, float(pair[1]))
		_put(el, "尺寸标注")
		doc.add_entity(el, false)
		var ln := EntLine.make(base + off, base + off + Vector2(0.0, -700.0))
		_put(ln, "尺寸标注")
		doc.add_entity(ln, false)

	var idx := EntSymbols.IndexMark.make_index(base + Vector2(0.0, -2000.0), "3", "建施-05")
	_put(idx, "尺寸标注")
	doc.add_entity(idx, false)
	var det := EntSymbols.IndexMark.make_detail(base + Vector2(2200.0, -2000.0), "3")
	_put(det, "尺寸标注")
	doc.add_entity(det, false)

	var sec := EntSymbols.SectionMark.make(Vector2(-4400.0, -900.0), Vector2(-4400.0, 6900.0), 1, "1")
	_put(sec, "尺寸标注")
	doc.add_entity(sec, false)

	var lead := EntSymbols.Leader.make(PackedVector2Array([
		base + Vector2(400.0, -3000.0), base + Vector2(1200.0, -3800.0),
		base + Vector2(3200.0, -3800.0)]), "外墙外保温做法见详图")
	_put(lead, "尺寸标注")
	doc.add_entity(lead, false)

	var bkl := EntSymbols.BreakLine.make(Vector2(-7800.0, -900.0), Vector2(-5400.0, -900.0))
	_put(bkl, "尺寸标注")
	doc.add_entity(bkl, false)
	var wavy := EntSymbols.BreakLine.make(Vector2(-7800.0, -1700.0), Vector2(-5400.0, -1700.0), true)
	_put(wavy, "尺寸标注")
	doc.add_entity(wavy, false)


# ---------------------------------------------------------------------------
# 材料图例展示条
# ---------------------------------------------------------------------------

## 用国标图例库生成若干常用建筑材料的填充，下方标注名称
static func _add_hatch_legend(doc: CadDocument) -> void:
	var patterns := ["钢筋混凝土", "多孔材料", "夯实土壤", "天然石材",
		"松散保温材料", "金属", "普通砖"]
	var cell := 800.0
	var gap := 200.0
	var x0 := -9400.0
	var y0 := -6600.0
	for i in range(patterns.size()):
		var bx := x0 + float(i) * (cell + gap)
		var pts := PackedVector2Array([
			Vector2(bx, y0), Vector2(bx + cell, y0),
			Vector2(bx + cell, y0 + cell), Vector2(bx, y0 + cell)])
		var outline := EntPolyline.make(pts, PackedFloat64Array(), true)
		_put(outline, "图例填充")
		doc.add_entity(outline, false)
		var h := EntHatch.make(pts, patterns[i])
		h.origin = pts[0]
		h.pattern_scale = 0.35
		_put(h, "图例填充")
		doc.add_entity(h, false)
		_center_text(doc, Vector2(bx + cell * 0.5, y0 - 220.0), patterns[i], 220.0)

	# 实心填充示例：剖切到的墙体常用 poché 表示
	var sx := x0 + float(patterns.size()) * (cell + gap)
	var spts := PackedVector2Array([
		Vector2(sx, y0), Vector2(sx + cell, y0),
		Vector2(sx + cell, y0 + cell), Vector2(sx, y0 + cell)])
	var soutline := EntPolyline.make(spts, PackedFloat64Array(), true)
	_put(soutline, "图例填充")
	doc.add_entity(soutline, false)
	var hs := EntHatch.make(spts, "实心")
	hs.solid = true
	_put(hs, "图例填充")
	doc.add_entity(hs, false)
	_center_text(doc, Vector2(sx + cell * 0.5, y0 - 220.0), "实心填充", 220.0)
