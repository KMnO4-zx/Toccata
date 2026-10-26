# shared/ — 契约与随包资源

- [protocol.md](protocol.md)：后台服务与 Studio 的 IPC、SQLite 表结构、任务语义和统计口径。
- `layout/magic-keyboard-ansi.json`：妙控键盘布局，定义“键盘活跃”页热力图的键码、标签与几何位置。
- `branding/`：项目 Logo PNG；运行 `swift scripts/generate-branding.swift` 可重新生成这些图像和 Studio 打包用的 `AppIcon.icns`。

修改键盘布局后，在项目根目录运行：

```bash
./scripts/sync-assets.sh
```

脚本将布局同步到 `apps/toccata-studio/Resources/Layout/`。随后重新构建 Studio；应用打包脚本也会执行同步。Studio 从应用资源包读取布局，没有数据目录中的运行时覆盖机制。`shared/layout/` 是布局的源文件目录，应用中的副本供 SwiftPM 打包使用。

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
| `rows` | 二维数组 | 按行保存的按键列表，用于计算各键帽的位置 |
| `code` | 整数或 `null` | macOS CGKeyCode，用于关联按键次数；`null` 项不关联按键记录 |
| `label` | 字符串 | 键帽上的文字；空字符串显示为 `Space` |
| `id` / `name` | 字符串 | 布局标识与名称，由布局模型读取 |
| `unit` / `keyGap` | 数字 | 妙控键盘的缩放单位与键帽间距 |
| `w` / `h` / `x` / `y` | 数字 | 妙控键盘键帽的大小与偏移 |
| `decor` | 布尔值 | 装饰项标记，由布局模型读取；缺省时按是否缺少键码判断 |

布局保留左右修饰键及半高方向键。`KeyboardLayout` 验证键码唯一性和几何尺寸；资源缺失或无效时，界面显示“键盘布局不可用”。

## 热度与外观

- 键盘热力图按所选日期范围内的每键次数计算 `log(1 + count) / log(1 + maxCount)`，在当前键盘各键之间比较热度；Fn 悬浮提示单独显示实际按住时长。
- 活跃日历按当前显示日期内的每日按键次数，用同样的对数公式归一化。非零日期以靛蓝色透明度区分深浅，无按键日期为浅灰色；配色定义在 `CalendarHeatmapView.swift` 中。
- 键盘活跃页的 15 分钟时间线按格内活跃时长着色，使用界面强调色。

界面通过 `AppearanceSettings` 统一选择“月之亮面”“月之暗面”或“跟随系统”，并保存用户选择。键盘热力图的浅色、深色配色定义在 `KeyboardHeatmapView.swift` 中；当前界面不使用外部主题 JSON。
