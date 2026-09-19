"""生成 Unicode -> GBK 编码表，供 DXF R12 导出使用。

为什么要这张表：
DXF R12 的中文用 GBK(ANSI_936) 编码，而 Godot 只支持 UTF-8/UTF-16/ASCII/Latin1，
无法在运行时做 GBK 转换。R2000+ 虽然可以用 UTF-8，但需要完整的
handle/owner 体系与 OBJECTS/CLASSES 段，手工构造极易出错。
权衡后选 R12 + 内嵌 GBK 表：结构简单可靠，所有 CAD 都能读。

表格式（二进制，小端）：
    uint32  count
    count × (uint16 unicode, uint16 gbk)
按 unicode 升序排列，查询时二分。
"""
import io
import os
import struct

pairs = []
# 遍历 BMP，筛出所有能用 GBK 编码且编码为双字节的字符
for cp in range(0x20, 0x10000):
    ch = chr(cp)
    try:
        b = ch.encode('gbk')
    except (UnicodeEncodeError, UnicodeDecodeError):
        continue
    if len(b) != 2:
        continue
    gbk = (b[0] << 8) | b[1]
    pairs.append((cp, gbk))

# 去重并排序（同一 GBK 码可能对应多个 Unicode，保留 Unicode 最小的）
seen = {}
for cp, gbk in pairs:
    if gbk not in seen or cp < seen[gbk]:
        seen[gbk] = cp
uniq = sorted((cp, gbk) for gbk, cp in seen.items())

out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets')
out_dir = os.path.normpath(out_dir)
os.makedirs(out_dir, exist_ok=True)
path = os.path.join(out_dir, 'gbk_table.bin')

with open(path, 'wb') as f:
    f.write(struct.pack('<I', len(uniq)))
    for cp, gbk in uniq:
        f.write(struct.pack('<HH', cp, gbk))

size = os.path.getsize(path)
print('字符数 =', len(uniq))
print('文件 =', path)
print('大小 = %.1f KB' % (size / 1024.0))

# 抽查几个常用字
probe = {}
for cp, gbk in uniq:
    probe[chr(cp)] = gbk
for ch in '一层平面图墙体门窗钢筋混凝土±':
    if ch in probe:
        b = ch.encode('gbk')
        ok = ((b[0] << 8) | b[1]) == probe[ch]
        print('  %s -> %02X%02X  校验=%s' % (ch, b[0], b[1], ok))
    else:
        print('  %s -> 表中缺失' % ch)
