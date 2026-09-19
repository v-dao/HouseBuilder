class_name SnapType
extends RefCounted
## 对象捕捉类型常量。顺序即捕捉优先级（数值小者优先）。
## 优先级参照 AutoCAD 的常用行为：端点 > 中点 > 圆心 > 象限点 > 交点 >
## 垂足 > 切点 > 节点 > 插入点 > 最近点。

const NONE := -1
const ENDPOINT := 0        ## 端点
const MIDPOINT := 1        ## 中点
const CENTER := 2          ## 圆心
const QUADRANT := 3        ## 象限点
const INTERSECTION := 4    ## 交点
const APPARENT_INTERSECT := 5  ## 外观交点
const PERPENDICULAR := 6   ## 垂足
const TANGENT := 7         ## 切点
const NODE := 8            ## 节点
const INSERTION := 9       ## 插入点
const NEAREST := 10        ## 最近点
const EXTENSION := 11      ## 延长线
const GRID := 12           ## 栅格
const POLAR := 13          ## 极轴追踪
const TRACK := 14          ## 对象捕捉追踪


const NAMES := {
	ENDPOINT: "端点",
	MIDPOINT: "中点",
	CENTER: "圆心",
	QUADRANT: "象限点",
	INTERSECTION: "交点",
	APPARENT_INTERSECT: "外观交点",
	PERPENDICULAR: "垂足",
	TANGENT: "切点",
	NODE: "节点",
	INSERTION: "插入点",
	NEAREST: "最近点",
	EXTENSION: "延长线",
	GRID: "栅格",
	POLAR: "极轴",
	TRACK: "追踪",
}


static func name_of(t: int) -> String:
	return NAMES.get(t, "未知")
