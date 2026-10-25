# shared/ — 契约与随包资源

- [protocol.md](protocol.md)：后台服务与 Studio 的 IPC、SQLite 表结构、任务语义和统计口径。
- `layout/`：键盘布局 JSON。Studio 当前读取其中的 `code` 和 `label`，为按键排行提供键名。
- `theme/`：主题 JSON。Studio 当前读取 `heatLow` 和 `heatHigh`，绘制活跃日历的颜色渐变。

修改资源后，在项目根目录运行：

```bash
./scripts/sync-assets.sh
```

脚本将资源同步到 `apps/toccata-studio/Resources/Layout/` 和 `Resources/Themes/`。随后重新构建 Studio；应用打包脚本也会执行同步。当前 Studio 从应用资源包读取这些 JSON，没有数据目录中的运行时覆盖机制。

## 布局 JSON

```json
{
  "id": "example",
  "name": "Example keyboard",
  "unit": 54,
  "keyGap": 6,
  "rows": [[
    { "code": 13, "label": "W" },
    { "code": 63, "label": "fn" },
    { "code": null, "label": "Touch ID", "decor": true }
  ]]
}
```

| 字段 | 类型 | 含义 |
|---|---|---|
| `rows` | 二维数组 | 按行保存的按键列表；Studio 遍历所有行建立键名映射 |
| `code` | 整数或 `null` | macOS CGKeyCode；`null` 项不进入键名映射 |
| `label` | 字符串 | 按键排行中的名称；空字符串显示为 `Space` |
| `id` / `name` | 字符串 | 布局标识与名称，当前 Studio 不读取 |
| `unit` / `keyGap` | 数字 | 妙控键盘的缩放单位与键帽间距 |
| `w` / `h` / `x` / `y` | 数字 | 妙控键盘键帽的大小与偏移 |
| `decor` | 布尔值 | 装饰项元数据，当前 Studio 不读取 |

`macbook-air-ansi.json` 用于按键名称映射，读取失败或键码未在表内时显示 `Key<code>`。`magic-keyboard-ansi.json` 用于“键盘与应用”页面的逐键热度，按真实 keycode 和几何位置绘制，保留左右修饰键及半高方向键。

## 主题 JSON

```json
{
  "name": "Light",
  "heatLow": "#FFE5D9",
  "heatHigh": "#D0342C"
}
```

颜色支持 `#RRGGBB` 和 `#RRGGBBAA`。日历按当天按键次数进行 `log(1 + count)` 归一化，在 `heatLow` 到 `heatHigh` 之间插值；无按键日期使用界面默认空白色。

Studio 根据系统的浅色/深色外观加载 `light.json` 或 `dark.json`。主题中的其他现有字段作为资源元数据保留，当前 Studio 不读取。读取或颜色解析失败时使用代码内置的默认日历配色。

键盘活跃页的 15 分钟时间线使用界面强调色，与日历主题 JSON 分开。
