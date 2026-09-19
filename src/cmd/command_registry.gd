class_name CommandRegistry
extends RefCounted
## 命令注册表：命令名、别名、说明，以及工厂方法。
##
## 别名沿用国内 CAD 用户的肌肉记忆（AutoCAD 简写），
## 同时支持中文名，降低新用户门槛。

## 命令定义表：[命令名, 别名数组, 分类, 说明]
const DEFS := [
	# --- 绘制 ---
	["LINE", ["L"], "绘制", "直线：连续点取各段端点"],
	["PLINE", ["PL", "多段线"], "绘制", "多段线：连续段可切换为圆弧（A/L）、闭合（C）、放弃（U）"],
	["RECTANG", ["REC", "矩形"], "绘制", "矩形：两个对角点，可选圆角半径（F）"],
	["POLYGON", ["POL", "正多边形"], "绘制", "正多边形：边数 + 中心 + 内接/外切 + 半径"],
	["CIRCLE", ["C", "圆"], "绘制", "圆：圆心+半径，或三点（3P）"],
	["ARC", ["A", "圆弧"], "绘制", "圆弧：起点、圆弧上一点、终点（三点画弧）"],
	["ELLIPSE", ["EL", "椭圆"], "绘制", "椭圆：长轴两端点 + 短半轴距离"],
	["SPLINE", ["SPL", "样条"], "绘制", "样条曲线：依次点取型值点，回车结束"],
	["POINT", ["PO", "点"], "绘制", "点：点取位置"],
	["XLINE", ["XL", "构造线"], "绘制", "构造线：一点 + 方向（双向无限，作辅助线用）"],
	["HATCH", ["H", "BH", "填充"], "绘制", "图案填充：图例名 + 内部点，或手选边界对象"],
	["SHEET", ["FRAME", "图框"], "设置", "插入国标图框（含标题栏与会签栏）"],
	["MODCHECK", ["MC", "模数校验"], "设置", "模数校验：检查选中图元的尺寸是否符合 GB/T 50002"],
	["BLOCK", ["B", "创建块"], "块", "定义块：选择对象 + 基点 + 块名"],
	["INSERT", ["I", "DDINSERT", "插入块"], "块", "插入块：块名 + 插入点 + 比例 + 旋转"],
	["ATTEDIT", ["ATE", "属性编辑"], "块", "编辑属性块各字段的值"],

	# --- 建筑 ---
	["AXISGRID", ["AG", "轴网"], "建筑", "参数化轴网：轴距 + 左下角，自动编号并生成三道尺寸"],
	["WALL", ["W", "墙", "双线墙"], "建筑", "参数化墙体：墙厚 + 中心线，门窗洞口自动断开墙线"],
	["DOOR", ["DR", "门"], "建筑", "插入门：编号 + 点取墙体 + 点取位置"],
	["WINDOW", ["WIN", "窗"], "建筑", "插入窗：编号 + 点取墙体 + 点取位置"],
	["ROOM", ["RM", "房间"], "建筑", "房间：点取内部一点，自动算净面积并标注"],
	["STAIR", ["ST", "楼梯"], "建筑", "参数化双跑楼梯：踏步数/踏步宽/梯段宽/平台深"],
	["SCHEDULE", ["SCHED", "门窗表"], "建筑", "门窗表：统计门窗洞口并生成表格"],
	["SHEETLIST", ["图纸目录"], "建筑", "图纸目录：统计各布局的图名图号并生成表格"],
	["MATLIST", ["材料做法表"], "建筑", "材料做法表：按标准做法模板生成表格"],
	["TEXT", ["DT", "T", "文字"], "绘制", "单行文字：位置 + 字高 + 内容"],
	["MTEXT", ["MT", "多行文字"], "绘制", "多行文字：字宽框 + 字高 + 内容（支持自动换行与分段）"],
	["TEXTEDIT", ["ED", "DDEDIT", "改文字"], "编辑", "修改文字：点取文字图元后改内容"],
	["QSELECT", ["QS", "快速选择"], "编辑", "快速选择：按类型/图层/颜色筛选并选中"],

	# --- 编辑 ---
	["ERASE", ["E", "删除"], "编辑", "删除选中的图元"],
	["MOVE", ["M", "移动"], "编辑", "移动：基点 + 目标点"],
	["COPY", ["CO", "CP", "复制"], "编辑", "复制：基点 + 目标点，可连续复制多个"],
	["ROTATE", ["RO", "旋转"], "编辑", "旋转：基点 + 角度"],
	["SCALE", ["SC", "缩放"], "编辑", "缩放：基点 + 比例"],
	["MIRROR", ["MI", "镜像"], "编辑", "镜像：两点定镜像轴，可选择是否删除原对象"],
	["STRETCH", ["S", "拉伸"], "编辑", "拉伸：交叉窗口选择，移动窗口内的定义点"],
	["ARRAY", ["AR", "阵列"], "编辑", "阵列：矩形（R）或环形（P）"],

	# --- 几何编辑 ---
	["OFFSET", ["O", "偏移"], "几何编辑", "偏移：距离 + 点取偏移侧"],
	["TRIM", ["TR", "修剪"], "几何编辑", "修剪：以选中的对象为边界，剪掉点取的部分"],
	["EXTEND", ["EX", "延伸"], "几何编辑", "延伸：以选中的对象为边界，延伸点取的一端"],
	["BREAK", ["BR", "打断"], "几何编辑", "打断：在两点处断开"],
	["FILLET", ["F", "圆角"], "几何编辑", "圆角：半径 + 点取两条线"],
	["CHAMFER", ["CHA", "倒角"], "几何编辑", "倒角：两个距离 + 点取两条线"],
	["EXPLODE", ["X", "分解"], "几何编辑", "分解：把多段线/块打散为基本图元"],
	["JOIN", ["J", "合并"], "几何编辑", "合并：把首尾相接的多段线合并为一条"],

# --- 标注 ---
["DIMLINEAR", ["DLI", "DL", "线性标注"], "标注", "线性标注：两点 + 尺寸线位置，自动判水平/竖直"],
["DIMALIGNED", ["DAL", "对齐标注"], "标注", "对齐标注：尺寸线平行于两点连线"],
["DIMRADIUS", ["DRA", "半径标注"], "标注", "半径标注：点取圆或圆弧 + 文字位置"],
["DIMDIAMETER", ["DDI", "直径标注"], "标注", "直径标注：点取圆或圆弧 + 文字位置"],
["DIMANGULAR", ["DAN", "角度标注"], "标注", "角度标注：顶点 + 两边上的点 + 圆弧位置"],
["DIMCONTINUE", ["DCO", "连续标注"], "标注", "连续标注：尺寸线首尾相接"],
["DIMBASELINE", ["DBA", "基线标注"], "标注", "基线标注：共用基准，逐层偏移"],

# --- 视图 ---
	# --- 符号 ---
	["ELEVATION", ["ELEV", "BG", "标高"], "符号", "标高符号：位置 + 标高值（米或毫米）"],
	["INDEXMARK", ["IDX", "索引符号"], "符号", "索引符号：位置 + 详图编号 + 图纸编号"],
	["DETAILMARK", ["DTM", "详图符号"], "符号", "详图符号：位置 + 详图编号"],
	["SECTIONMARK", ["SEC", "剖切符号"], "符号", "剖切符号：剖切位置线 + 投射方向 + 编号"],
	["LEADER", ["LE", "引出线"], "符号", "引出线：起点 + 折点 + 文字"],
	["BREAKLINE", ["BKL", "折断线"], "符号", "折断线：直线折断画成 Z 字形"],
	["WAVYLINE", ["WAVY", "波浪线"], "符号", "波浪线：曲线折断用"],
	["AXISBUBBLE", ["AXB", "轴线号"], "符号", "轴线号：位置 + 编号"],

	["ZOOM", ["Z"], "视图", "缩放到图纸范围"],
	["UNDO", ["U", "撤销"], "视图", "撤销上一步"],
	["REDO", [], "视图", "重做"],

	# --- 状态 ---
	["LAYER", ["LA", "图层"], "设置", "图层管理器"],
	["LWDISPLAY", [], "设置", "切换线宽显示"],
]


## 名称/别名 -> 规范命令名
static func _alias_map() -> Dictionary:
	var m := {}
	for d in DEFS:
		var name := String(d[0])
		m[name.to_lower()] = name
		for a in (d[1] as Array):
			m[String(a).to_lower()] = name
	return m


static var _map_cache: Dictionary = {}


static func normalize(input: String) -> String:
	if _map_cache.is_empty():
		_map_cache = _alias_map()
	return _map_cache.get(input.strip_edges().to_lower(), "")


static func is_command(input: String) -> bool:
	return normalize(input) != ""


static func help_for(name: String) -> String:
	var n := normalize(name)
	for d in DEFS:
		if String(d[0]) == n:
			return String(d[3])
	return ""


static func category_of(name: String) -> String:
	var n := normalize(name)
	for d in DEFS:
		if String(d[0]) == n:
			return String(d[2])
	return ""


## 按分类列出命令，供工具栏/帮助面板使用
static func by_category() -> Dictionary:
	var out := {}
	for d in DEFS:
		var cat := String(d[2])
		if not out.has(cat):
			out[cat] = []
		out[cat].append([String(d[0]), String(d[3])])
	return out


## 前缀补全候选
static func complete(prefix: String) -> Array[String]:
	var pfx := prefix.strip_edges().to_lower()
	var out: Array[String] = []
	if pfx == "":
		return out
	for d in DEFS:
		var n := String(d[0])
		if n.to_lower().begins_with(pfx):
			out.append(n)
			continue
		for a in (d[1] as Array):
			if String(a).to_lower().begins_with(pfx):
				out.append("%s (%s)" % [n, String(a)])
				break
	return out


## 工厂：按名称创建命令实例
static func create(name: String) -> CadCommand:
	match normalize(name):
		"LINE":
			return CmdLine.new()
		"PLINE":
			return CmdDraw.Pline.new()
		"RECTANG":
			return CmdDraw.Rectang.new()
		"POLYGON":
			return CmdDraw.Polygon.new()
		"CIRCLE":
			return CmdDraw.CircleCmd.new()
		"ARC":
			return CmdDraw.ArcCmd.new()
		"ELLIPSE":
			return CmdDraw.EllipseCmd.new()
		"SPLINE":
			return CmdDraw.SplineCmd.new()
		"POINT":
			return CmdDraw.PointCmd.new()
		"XLINE":
			return CmdDraw.XlineCmd.new()
		"ERASE":
			return CmdModify.Erase.new()
		"MOVE":
			return CmdModify.Move.new()
		"COPY":
			return CmdModify.Copy.new()
		"ROTATE":
			return CmdModify.Rotate.new()
		"SCALE":
			return CmdModify.Scale.new()
		"MIRROR":
			return CmdModify.Mirror.new()
		"STRETCH":
			return CmdModify.Stretch.new()
		"ARRAY":
			return CmdGeom.ArrayCmd.new()
		"OFFSET":
			return CmdGeom.Offset.new()
		"TRIM":
			return CmdGeom.Trim.new()
		"EXTEND":
			return CmdGeom.Extend.new()
		"BREAK":
			return CmdGeom.Break.new()
		"FILLET":
			return CmdGeom.Fillet.new()
		"CHAMFER":
			return CmdGeom.Chamfer.new()
		"EXPLODE":
			return CmdGeom.Explode.new()
		"JOIN":
			return CmdGeom.Join.new()
		"DIMLINEAR":
			return CmdDim.DimLinear.new()
		"DIMALIGNED":
			return CmdDim.DimAligned.new()
		"DIMRADIUS":
			return CmdDim.DimRadial.new(false)
		"DIMDIAMETER":
			return CmdDim.DimRadial.new(true)
		"DIMANGULAR":
			return CmdDim.DimAngular.new()
		"DIMCONTINUE":
			return CmdDim.DimChain.new(false)
		"DIMBASELINE":
			return CmdDim.DimChain.new(true)
		"ELEVATION":
			return CmdSymbol.Elevation.new()
		"INDEXMARK":
			return CmdSymbol.IndexMark.new(false)
		"DETAILMARK":
			return CmdSymbol.IndexMark.new(true)
		"SECTIONMARK":
			return CmdSymbol.SectionMark.new()
		"LEADER":
			return CmdSymbol.Leader.new()
		"BREAKLINE":
			return CmdSymbol.BreakLine.new(false)
		"WAVYLINE":
			return CmdSymbol.BreakLine.new(true)
		"AXISBUBBLE":
			return CmdSymbol.AxisBubble.new()
		"TEXT":
			return CmdText.TextSingle.new()
		"MTEXT":
			return CmdText.TextMulti.new()
		"TEXTEDIT":
			return CmdText.TextChange.new()
		"HATCH":
			return CmdHatch.HatchCmd.new()
		"SHEET":
			return CmdSheet.SheetCmd.new()
		"BLOCK":
			return CmdBlock.BlockCmd.new()
		"INSERT":
			return CmdBlock.InsertCmd.new()
		"ATTEDIT":
			return CmdBlock.AttEdit.new()
		"AXISGRID":
			return CmdArch.AxisGridCmd.new()
		"WALL":
			return CmdArch.WallCmd.new()
		"DOOR":
			return CmdArch.OpeningCmd.new(false)
		"WINDOW":
			return CmdArch.OpeningCmd.new(true)
		"ROOM":
			return CmdArch.RoomCmd.new()
		"STAIR":
			return CmdArch.StairCmd.new()
		"SCHEDULE":
			return CmdArch.ScheduleCmd.new()
		"QSELECT":
			return CmdTables.QuickSelect.new()
		"SHEETLIST":
			return CmdTables.SheetList.new()
		"MATLIST":
			return CmdTables.MaterialTable.new()
		"MODCHECK":
			return CmdTables.ModCheck.new()
	return null


## 该命令是否需要先有选择集（否则进入"先选对象"状态）
static func needs_selection(name: String) -> bool:
	match normalize(name):
		"ERASE", "MOVE", "COPY", "ROTATE", "SCALE", "MIRROR", "STRETCH", "EXPLODE", "JOIN", "ARRAY":
			return true
	return false


## 该命令是否需要点取对象（而非选择集）
static func picks_objects(name: String) -> bool:
	match normalize(name):
		"OFFSET", "TRIM", "EXTEND", "BREAK", "FILLET", "CHAMFER":
			return true
	return false
