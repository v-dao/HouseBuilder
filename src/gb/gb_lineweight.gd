class_name GbLineweight
extends RefCounted
## GB/T 50001—2017《房屋建筑制图统一标准》线宽体系。
##
## 第 4 章规定：
##   · 图线宽度 b 应从 **1.4 / 1.0 / 0.7 / 0.5 mm** 中选取
##   · 线宽组由 b、0.7b、0.5b、0.25b 组成，同一组内的线宽按此比例取用
##   · 图线宽度 **不得小于 0.1mm**
##   · 比例较大的图（如详图）b 取 1.4，中比例取 1.0 或 0.7，小比例取 0.5
##
## 常用 b 取值：
##   1:1 ~ 1:10   详图       b = 1.4
##   1:20 ~ 1:50  详图/大样  b = 1.0
##   1:100        平立剖面   b = 1.0 或 0.7
##   1:200 及更小 总图       b = 0.5
##
## 本模块只定义"线宽"这一维；"什么图线用哪个线宽"由 GB/T 50104 的用途映射给出。

## 可选的基本线宽 b (mm)
const B_CHOICES := [1.4, 1.0, 0.7, 0.5]

## 图线宽度下限 (mm)
const MIN_WIDTH := 0.1

## 组内比例
const RATIO_COARSE := 1.0      ## 粗线 b
const RATIO_MEDIUM_COARSE := 0.7  ## 中粗线 0.7b
const RATIO_MEDIUM := 0.5      ## 中粗线 0.5b
const RATIO_FINE := 0.25       ## 细线 0.25b


## 由基本线宽 b 生成完整线宽组（去重、升序）
static func group(b: float) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for r in [RATIO_FINE, RATIO_MEDIUM, RATIO_MEDIUM_COARSE, RATIO_COARSE]:
		var w := maxf(b * r, MIN_WIDTH)
		if not out.has(w):
			out.append(w)
	return out


## 按出图比例推荐基本线宽 b
static func b_for_plot_scale(denominator: float) -> float:
	if denominator <= 10.0:
		return 1.4
	if denominator <= 50.0:
		return 1.0
	if denominator <= 100.0:
		return 1.0
	if denominator <= 200.0:
		return 0.7
	return 0.5


## 把任意线宽吸附到最近的合法线宽组取值，避免出现非标线宽
static func snap(b: float, width: float) -> float:
	var g := group(b)
	var best := g[0]
	var best_d := absf(g[0] - width)
	for w in g:
		var d := absf(w - width)
		if d < best_d:
			best_d = d
			best = w
	return best


# ---------------------------------------------------------------------------
# GB/T 50104—2010《建筑制图标准》图线用途 -> 线宽
# ---------------------------------------------------------------------------

## 建筑专业图线用途。键为用途名，值为 [线宽比例, 说明]
## 比例是相对基本线宽 b 的倍数。
const USAGE := {
	"剖切主轮廓": [1.0, "平/剖面图中被剖切的主要建筑构造轮廓、立面外轮廓、构造详图被剖切的主要部分"],
	"次要轮廓": [0.7, "被剖切的次要建筑构造轮廓、构配件轮廓、详图一般轮廓"],
	"建筑构配件": [0.7, "平立剖面图中的建筑构配件轮廓"],
	"尺寸与符号": [0.5, "尺寸线、尺寸界线、索引符号、标高符号、引出线、粉刷线"],
	"不可见轮廓": [0.7, "中粗虚线，不可见轮廓线"],
	"图例填充": [0.25, "图例填充线、家具线、纹样线、断开界线"],
	"定位轴线": [0.25, "细单点长画线，中心线、对称线、定位轴线"],
	"相邻建筑": [0.25, "细双点长画线，相邻/原有/拆除建筑物轮廓线"],
	"地下部分": [1.0, "粗虚线，地下建筑平面与剖面中的地下部分"],
}


## 取某用途的线宽 (mm)
static func width_for(usage: String, b: float) -> float:
	var e = USAGE.get(usage)
	if e == null:
		return maxf(b * RATIO_FINE, MIN_WIDTH)
	return maxf(b * float(e[0]), MIN_WIDTH)


# ---------------------------------------------------------------------------
# 图层 -> 线宽 的默认映射
# ---------------------------------------------------------------------------

## 国内建筑制图常见的图层组织及其对应的 GB 线宽用途。
## 返回 [图层名, 线型名, 用途, 说明]
static func default_layer_map() -> Array:
	return [
		["轴线", "CENTER", "定位轴线", "定位轴线、中心线、对称线"],
		["墙体", "CONTINUOUS", "剖切主轮廓", "墙体剖切轮廓（粗实线）"],
		["柱", "CONTINUOUS", "剖切主轮廓", "柱剖切轮廓（粗实线）"],
		["门窗", "CONTINUOUS", "建筑构配件", "门窗及构配件轮廓（中粗实线）"],
		["楼梯", "CONTINUOUS", "建筑构配件", "楼梯踏步、栏杆、扶手"],
		["尺寸标注", "CONTINUOUS", "尺寸与符号", "尺寸线、尺寸界线、符号（中实线）"],
		["文字", "CONTINUOUS", "图例填充", "文字与说明（细线）"],
		["图例填充", "CONTINUOUS", "图例填充", "材料图例、填充线（细实线）"],
		["家具", "CONTINUOUS", "图例填充", "家具、洁具（细实线）"],
		["设备", "CONTINUOUS", "图例填充", "设备轮廓与点位"],
		["不可见", "DASHED", "不可见轮廓", "不可见轮廓线（中粗虚线）"],
		["图框", "CONTINUOUS", "剖切主轮廓", "图框线、标题栏外框"],
		["原有建筑", "PHANTOM", "相邻建筑", "原有/相邻/拆除建筑物轮廓"],
	]
