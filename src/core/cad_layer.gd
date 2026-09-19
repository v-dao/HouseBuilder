class_name CadLayer
extends RefCounted
## 图层。对应 DXF 的 LAYER 表项。
##
## 国标 GB/T 50001—2017 专门增补了"计算机制图文件与图层管理"的要求。
## 实际工程做法是用「图层 → 颜色 → 打印线宽」的映射，配合打印样式表（.ctb）出图，
## 因此颜色与线宽必须能独立于图元本身被覆盖。

## 线宽哨兵值（与 DXF 约定一致）
const LW_BYLAYER := -1.0
const LW_BYBLOCK := -2.0
const LW_DEFAULT := -3.0

var name: String = "0"
var color: Color = Color.WHITE
## AutoCAD 颜色索引（ACI）。用于 DXF 往返与打印样式表映射。
var aci: int = 7
var linetype: String = "CONTINUOUS"
## 线宽，单位 mm。为负值时取上面的哨兵值。
var lineweight: float = LW_DEFAULT
var visible: bool = true
var frozen: bool = false
var locked: bool = false
var printable: bool = true
var description: String = ""
## 透明度 0~1，1 为完全不透明。国标图一般不用，但遮罩/参考底图需要。
var alpha: float = 1.0


static func make(p_name: String, p_color: Color, p_aci: int, p_linetype: String, p_lw: float, p_desc := "") -> CadLayer:
	var l := CadLayer.new()
	l.name = p_name
	l.color = p_color
	l.aci = p_aci
	l.linetype = p_linetype
	l.lineweight = p_lw
	l.description = p_desc
	return l


## 是否可被拾取（关闭、冻结、锁定都不可编辑）
func is_selectable() -> bool:
	return visible and not frozen and not locked


## 是否参与显示
func is_displayable() -> bool:
	return visible and not frozen


func duplicate_layer() -> CadLayer:
	var l := CadLayer.new()
	l.name = name
	l.color = color
	l.aci = aci
	l.linetype = linetype
	l.lineweight = lineweight
	l.visible = visible
	l.frozen = frozen
	l.locked = locked
	l.printable = printable
	l.description = description
	l.alpha = alpha
	return l
