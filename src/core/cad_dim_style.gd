class_name CadDimStyle
extends RefCounted
## 标注样式。对应 DXF 的 DIMSTYLE 表项。
##
## 默认值全部取自 GB/T 50001—2017《房屋建筑制图统一标准》第 11 章"尺寸标注"：
##   · 尺寸界线用细实线，自图形轮廓线/轴线/对称中心线引出，并超出尺寸线 2~3mm
##   · 尺寸起止符号用中粗斜短线，与尺寸线成 45°，长 2~3mm
##     （也可用箭头，长 3~4mm；或圆点，直径 1mm）
##   · 尺寸线用细实线，与被标注长度平行，距图样轮廓线不宜小于 10mm
##   · 互相平行的尺寸线间距宜为 7~10mm
##   · 尺寸数字字高 2.5 或 3.5mm，注写在尺寸线上方中部

## 起止符号形式
enum Terminator {
	OBLIQUE,   ## 中粗斜短线 45°（国标建筑制图首选）
	ARROW,     ## 箭头
	DOT,       ## 圆点
	NONE,      ## 无（建筑外墙三道尺寸常用）
}

var name: String = "国标-2.5"

# --- 尺寸线 ---
var dim_line_color: Color = Color(1, 1, 1)
var dim_line_weight: float = 0.25          ## 线宽 (mm)，细实线 0.25b
var dim_line_extension: float = 0.0        ## 尺寸线超出起止符号的长度 (mm)

# --- 尺寸界线 ---
var ext_line_color: Color = Color(1, 1, 1)
var ext_line_weight: float = 0.25
var ext_line_extension: float = 2.5        ## 超出尺寸线的长度 (mm)，国标 2~3
var ext_line_offset: float = 2.0           ## 相对轮廓线的偏移 (mm)
var ext_line_fixed_length: float = 0.0     ## >0 时使用固定长度（代替偏移）

# --- 起止符号 ---
var terminator: int = Terminator.OBLIQUE
var terminator_size: float = 2.5           ## 斜短线长 (mm)，国标 2~3
var arrow_size: float = 3.5                ## 箭头长 (mm)，国标 3~4
var dot_size: float = 1.0                  ## 圆点直径 (mm)
var terminator_weight: float = 0.7         ## 中粗线宽（0.7b）

# --- 文字 ---
var text_style: String = "标注_2.5"
var text_height: float = 2.5               ## 字高 (mm)，国标 2.5 或 3.5
var text_color: Color = Color(1, 1, 1)
var text_gap: float = 1.0                  ## 文字距尺寸线的间隙 (mm)
var text_align_above: bool = true          ## true = 文字在尺寸线上方（国标）
var text_inside: bool = false              ## 尺寸过小时文字是否移到尺寸线外侧
var text_round: int = 0                    ## 小数位数
var prefix: String = ""
var suffix: String = ""
var suppress_zeros: bool = true

# --- 排列 ---
var baseline_spacing: float = 8.0          ## 平行尺寸线间距 (mm)，国标 7~10
var origin_offset: float = 10.0            ## 第一条尺寸线距轮廓线的最小距离 (mm)，国标 ≥10
var overall_scale: float = 1.0             ## 标注全局比例（用于不同出图比例）

# --- 特殊标注 ---
## 标高符号：等腰直角三角形，高约 3mm；数字以米为单位，三位小数
var elevation_symbol_size: float = 3.0
var elevation_decimals: int = 3
## 半径/直径前缀（国标用 R / ⌀）
var radius_prefix: String = "R"
var diameter_prefix: String = "⌀"


static func make(p_name := "国标-2.5") -> CadDimStyle:
	var s := CadDimStyle.new()
	s.name = p_name
	return s


## 应用出图比例：国标要求标注元素（起止符号、文字、间距）随比例放大，
## 使打印到图纸上的尺寸保持恒定。
func apply_scale(plot_scale: float) -> void:
	overall_scale = plot_scale


## 换算到模型空间的尺寸（标注元素按 overall_scale 放大）
func scaled(v: float) -> float:
	return v * overall_scale


func duplicate_style() -> CadDimStyle:
	var s := CadDimStyle.new()
	s.name = name
	s.dim_line_color = dim_line_color
	s.dim_line_weight = dim_line_weight
	s.dim_line_extension = dim_line_extension
	s.ext_line_color = ext_line_color
	s.ext_line_weight = ext_line_weight
	s.ext_line_extension = ext_line_extension
	s.ext_line_offset = ext_line_offset
	s.ext_line_fixed_length = ext_line_fixed_length
	s.terminator = terminator
	s.terminator_size = terminator_size
	s.arrow_size = arrow_size
	s.dot_size = dot_size
	s.terminator_weight = terminator_weight
	s.text_style = text_style
	s.text_height = text_height
	s.text_color = text_color
	s.text_gap = text_gap
	s.text_align_above = text_align_above
	s.text_inside = text_inside
	s.text_round = text_round
	s.prefix = prefix
	s.suffix = suffix
	s.suppress_zeros = suppress_zeros
	s.baseline_spacing = baseline_spacing
	s.origin_offset = origin_offset
	s.overall_scale = overall_scale
	s.elevation_symbol_size = elevation_symbol_size
	s.elevation_decimals = elevation_decimals
	s.radius_prefix = radius_prefix
	s.diameter_prefix = diameter_prefix
	return s


# ---------------------------------------------------------------------------
# 国标标注样式库
# ---------------------------------------------------------------------------

## 按出图比例生成一组常用标注样式
static func gb_library() -> Dictionary:
	var lib := {}

	var s100 := make("国标-1:100")
	s100.apply_scale(100.0)
	lib[s100.name] = s100

	var s50 := make("国标-1:50")
	s50.text_height = 3.5
	s50.apply_scale(50.0)
	lib[s50.name] = s50

	var s30 := make("国标-1:30")
	s30.text_height = 3.5
	s30.baseline_spacing = 10.0
	s30.apply_scale(30.0)
	lib[s30.name] = s30

	# 详图比例较大，起止符号改用箭头更清晰
	var s10 := make("国标-详图-1:10")
	s10.text_height = 3.5
	s10.terminator = Terminator.ARROW
	s10.terminator_size = 3.5
	s10.apply_scale(10.0)
	lib[s10.name] = s10

	return lib
