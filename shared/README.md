# shared/ — 布局与主题规范

Toccata 的键盘布局和配色全部外置为 JSON，可替换 = 换肤。

## 布局 JSON（layout/）

```json
{
  "id": "macbook-air-ansi",
  "name": "MacBook Air (ANSI)",
  "unit": 54,        // 1u 的像素基准（overlay 按窗口宽度等比缩放）
  "keyGap": 6,       // 键与键之间的像素间距（按 1u=unit 基准）
  "rows": [ [ <key>, ... ], ... ]
}
```

每个 `<key>`：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `code` | u16 或 null | — | CGKeyCode；`null` = 纯装饰键（如 Touch ID），不参与点亮/统计 |
| `label` | string | `""` | 键帽文字 |
| `w` | number | 1 | 宽（单位 u） |
| `h` | number | 1 | 高（单位 u），半高键用 0.5 |
| `x` | number | 0 | 绘制前的额外水平偏移（u），可为负（配合半高键回退一列） |
| `y` | number | 0 | 行内垂直偏移（u），半高键在下排用 0.5 |
| `decor` | bool | false | 装饰键标记 |

渲染规则：每行光标 x 从 0 开始，行 y 为行号。对每个键：`cursor += key.x`；在 `(cursor, rowY + key.y)` 处绘制 `w × h` 的键帽；然后 `cursor += w`。窗口按最宽行等比缩放。

方向键四键的半高布局示例见 `macbook-air-ansi.json` 最后一行（`up` 在上排，`down` 用 `x: -1` 回退到同一列的下排）。

## 主题 JSON（theme/）

所有颜色为 `#RRGGBB` 或 `#RRGGBBAA`：

| 字段 | 说明 |
|---|---|
| `name` | 主题名（菜单里显示） |
| `windowBackground` | 悬浮窗背景 |
| `keycap` / `keycapBorder` | 键帽填充 / 描边 |
| `label` | 键帽文字 |
| `pressed` / `pressedLabel` | 实时模式按下态填充 / 文字 |
| `heatLow` / `heatHigh` | 热力模式渐变两端（log 归一化后插值） |
| `heatLabel` | 热力模式文字 |
| `decor` | 装饰键填充 |

## 覆盖机制

App 内置一份默认（构建时由 `scripts/sync-assets.sh` 从本目录同步）。运行时优先读取 `~/Library/Application Support/Toccata/{layouts,themes}/` 下的同名 JSON——换肤只需丢一个 JSON 文件进去，无需重新编译。
