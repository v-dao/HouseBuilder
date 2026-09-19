# GDScript 编码约定与陷阱

Godot 4.7 的 GDScript 有几处与常见语言直觉不符的地方，本项目已全部踩过一遍。
这些坑在后续阶段会反复出现，务必按本文的写法处理。

---

## 1. Godot 4 把"从 Variant 推断类型"当作**编译错误**

本项目未修改警告等级，4.7 默认就把 `INFERENCE_ON_VARIANT` 视为错误。
以下写法会直接编译失败：

| 错误写法 | 报错 | 正确写法 |
|---|---|---|
| `var x := dict.get(k)` | 类型从 Variant 推断 | `var x: T = dict.get(k)` 或先 `if dict.has(k)` |
| `var x := arr.pop_back()` | 同上 | `var x: T = arr.pop_back()` |
| `var x := floor(v)` | `floor()` 返回 Variant | `var x := floorf(v)` |
| `var x := ceil(v)` | 同上 | `var x := ceilf(v)` |
| `var x := round(v)` | 同上 | `var x := roundf(v)` |
| `for e in untyped_array:` 后 `var d := e.to_dict()` | e 是 Variant | `for e: CadEntity in untyped_array:` |
| `for s in [-1.0, 1.0]:` 后 `var t := s * x` | s 是 Variant | `for s in PackedFloat64Array([-1.0, 1.0]):` |
| `var idx := array.find(x)` | 实际返回 int，可用 | — |

**规律：Godot 4 的全局数学函数 `abs/floor/ceil/round/sign/max/min` 都返回 Variant，
带 `f` 后缀的 `absf/floorf/ceilf/roundf/signf/maxf/minf` 才返回 float。**
本项目一律使用带 `f` 后缀的版本。

`Dictionary.get()` 在键不存在时返回 `null`，把 null 赋给类型化变量（尤其
`PackedVector2Array` 这类值类型）会**运行时报错**，必须显式 `has()` 判断：

```gdscript
if _buckets.has(key):
    return _buckets[key]
var b := PackedVector2Array()
_buckets[key] = b
return b
```

## 2. `PackedXxxArray(...)` 不能出现在常量表达式中

```gdscript
# 编译错误：Assigned value for constant "X" isn't a constant expression
const HEIGHTS: PackedFloat64Array = PackedFloat64Array([2.5, 3.5, 5.0])

# 正确：用普通数组常量
const HEIGHTS := [2.5, 3.5, 5.0]
```

需要 `PackedFloat64Array` 时在运行时构造。

## 3. `Transform2D` 没有 6 个标量的构造函数

```gdscript
# 编译错误：No constructor of Transform2D matches the signature "Transform2D(float x6)"
Transform2D(0.7, 0.0, 0.0, 1.0, 0.0, 0.0)

# 正确：列向量形式（x 轴、y 轴、原点）
Transform2D(Vector2(0.7, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
```

长仿宋的 0.7 横向压缩、75° 斜体剪切都依赖这个写法。

## 4. 字符串格式化不支持 `%e` 和 `%g`

```gdscript
# 报错：String formatting error: unsupported format character
"%.3e" % v
"%g" % v

# 可用：%s %d %f %x %o %c
"%s" % str(v)
"%.9f" % v
```

打印小到需要科学计数法的误差时，用 `str(v)` 走 `%s`。

## 5. 基类实例方法与子类静态工厂不能同名

```gdscript
class_name CadEntity
func from_dict(d: Dictionary) -> void:   # 实例方法

class_name EntLine
static func from_dict(d: Dictionary) -> EntLine:   # 静态工厂
# 报错：The function signature doesn't match the parent.
#       Parent signature is "from_dict(Dictionary) -> void"
```

本项目把基类方法命名为 `read_base_fields()`，子类工厂保持 `from_dict()`。
**新增实体类型时，`from_dict()` 里必须调用 `read_base_fields(d)`**，
否则图层/颜色/线宽会在存读档与撤销恢复时丢失（这个 bug 已被单元测试捕获过一次）。

## 6. `class_name` 全局类需要先生成缓存

新克隆的项目或新建脚本后，直接跑会报 `Identifier "Xxx" not declared in the current scope`。
先执行一次导入以生成 `.godot/global_script_class_cache.cfg`：

```bash
godot --headless --path <项目> --import
```

## 7. `--script` 只接受 `SceneTree` / `MainLoop`

```bash
# 报错：Can't load the script as it doesn't inherit from SceneTree or MainLoop
godot --headless --script res://tests/foo.gd      # foo.gd 是 extends Node

# 正确：要么让脚本 extends SceneTree，要么以场景方式运行
godot --path <项目> res://tests/foo.tscn
```

## 8. 循环依赖会让全局类退化成裸 `GDScript`

报错形式是 `Nonexistent function 'new' in base 'GDScript'`，
看起来像"类不存在"，实际是类之间的互相引用形成了环。
本项目的依赖方向是单向的：

```
core  ->  geom  ->  (Tol)
core  ->  gb
render ->  core, geom
cmd   ->  core, geom, render
ui    ->  cmd, render, core
app   ->  全部
```

**反向引用（geom 引用 core、core 引用 render）会破坏这个方向，必须避免。**

## 9. 坐标系与单位约定

- 模型空间单位是**毫米**，与建筑制图一致（开间 3600、墙厚 240）
- 模型空间 **Y 轴向上**，屏幕 Y 轴向下，转换集中在 `ViewTransform`
- 角度以 +X 轴为 0、逆时针为正
- 所有屏幕像素相关的量（拾取容差、圆弧细分矢高、线宽显示）都必须经
  `ViewTransform` 换算，不允许在别处硬编码像素值

## 10. 精度

`Vector2` 内部是 32 位浮点，在 30000mm（30 米跨度）处的最小分辨率约 0.0018mm。
因此 `Tol.POINT = Tol.DIST = 0.001mm`，从 `Vector2` 反算角度的精度上限约 1e-7 rad，
故 `Tol.ANGLE = 1e-6`。**写测试时不要用比这更严的容差，否则测的是浮点误差而非逻辑。**

涉及长链累加（求交、偏移）的标量运算使用 GDScript 的 `float`（64 位双精度）。
