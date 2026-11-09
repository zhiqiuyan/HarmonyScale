# 轻秤 · HarmonyScale

鸿蒙（HarmonyOS NEXT / ArkTS）蓝牙体重秤应用。支持市面上主流蓝牙体重秤与体脂秤，
提供实时称重、BMI 计算与分级、身体成分估算、历史趋势与本地隐私存储。

**当前状态**：DevEco Studio 26 / HarmonyOS SDK API 26 下 `assembleHap` 构建成功，
ArkTS 严格编译 0 错误；协议解析 40 项断言全部通过（见下文「验证」）。
最近一次实跑：`bash scripts/build.sh` → `TYPE CHECK SUCCESSFUL` → `BUILD SUCCESSFUL`（34 tasks / 16.2 s），
产物 `entry-default-unsigned.hap` 592,925 B（未签名，需 DevEco 配置 signingConfigs 后装真机）。
构建脚本兼容含中文的工程路径（内部会同步到纯 ASCII 临时目录再构建）。

---

## 1. 快速开始

### 环境要求

- DevEco Studio 26（默认安装路径 `C:\Program Files\Huawei\DevEco Studio`）
- HarmonyOS SDK，`compatibleSdkVersion` / `targetSdkVersion` = `6.0.0(20)`
- Node.js（仅验证脚本需要）

### 构建

```bash
cd HarmonyScale
bash scripts/build.sh
```

产物：`entry/build/outputs/default/entry-default-unsigned.hap`

应用图标为**分层资源**，需重新生成时执行（脚本产出背景层/前景层/合成图/启动图标，并写入 `entry` 与 `AppScope` 两套 media 目录）：

```bash
node scripts/gen-icons.cjs
```

默认配色为「青屿」（低饱和青绿纯色 `#0D7377`）。脚本内 `SOLID_COLORS` 预置 `teal` / `indigo` / `coral` 三套，
改 `const PALETTE = 'teal'` 一行并重新执行即可换色；三套均保证白色前景对比度 ≥3:1。
应用内主题色（按钮/胶囊/图表）运行时可在「我的」页的「中国式传统颜色」色板切换，与该常量解耦。

> **为什么要构建脚本**：hvigor 要求工程路径只含 ASCII 字符，而本工作区路径含中文。
> 脚本会把工程同步到 `C:\temp\harmonyscale-build\HarmonyScale` 再构建，并把 HAP 拷回工作区。
> 同时把 DevEco 自带的 JBR 加入 PATH（打包阶段需要 `java`）。
> 可用 `HARMONYSCALE_BUILD_ROOT` 覆盖临时构建目录。

也可直接用 DevEco Studio 打开 `HarmonyScale` 目录，配好签名后 Run 到真机。

### 安装到真机

HAP 目前是 **unsigned**（未配置 `signingConfigs`）。需要：
1. 在 DevEco Studio 中 `File > Project Structure > Signing Configs` 自动生成调试签名，或
2. 用 `hap-sign-tool` 手动签名。

蓝牙权限为 `user_grant`，首次启动会申请「蓝牙」与「位置」权限。

### 验证协议解析

```bash
node scripts/verify-protocols.cjs
```

脚本把真实的 `.ets` 协议模块用 TypeScript 转译为 CommonJS 后在 Node 中执行，
喂入构造的字节帧并断言输出。当前 **40 项断言全部通过**，覆盖：
字节序工具、BMI 与分级、标准 BLE Profile、小米 v1/v2、云麦、QN Scale、
VScale、广播型秤、scales-bridge 文本协议（含拆包/粘包）、协议注册表识别优先级。

---

## 2. 调研依据

| 来源 | 用途 |
|---|---|
| [xiangbohua/scales-bridge](https://github.com/xiangbohua/scales-bridge) | 用户点名仓库。Java/Android 串口电子秤库，`WeightDataProtocol` 插件化设计；移植其 A/B/C 三套 ASCII 帧格式（18B 定长帧、`0x0A` 起始、`0x0D` 结束、`ST/US/OL` 状态位、`GS/NT` 类型、`KG/LB` 单位）与「协议工厂 + 统一 DTO」的架构思想 |
| [oliexdev/openScale](https://github.com/oliexdev/openScale) | 75 个厂商驱动，用于核对小米、云麦、QN、Exingtech、Sinocare 等 GATT UUID 与字节帧布局 |
| Bluetooth SIG Weight Scale Profile 1.0 / 华为运动健康设备接入文档 | 标准 `0x181D / 0x2A9D` 帧字段（Flags、SI 0.005kg、Imperial 0.01lb、时间戳、BMI/Height） |
| 华为开发者文档 `@ohos.bluetooth.ble` 与 SDK `.d.ts` | 鸿蒙 BLE API 的真实签名（详见「第 6 节 踩过的坑」） |
| WS/T 428-2013 / WHO | 中国与 WHO 的 BMI 分级阈值 |

**关于 scales-bridge 的注意点**：该库 `ProtocolFactory` 实际只注册了协议 `B`，
`A` 与 `C` 是未启用的代码；且 `WeightDataProtocolC` 的 `totalDataLength()` 返回 8，
但 `readWeightValue()` 却读 `[6,13)`，存在越界。本实现保留其帧语义，
但用「字节流缓冲 + 结束符切帧 + 正则兜底」重写了分帧逻辑，不复制该缺陷。

---

## 3. 已适配设备与协议

| # | 适配器 | 覆盖设备 | 传输方式 | 关键 UUID / 识别 | 帧要点 |
|---|---|---|---|---|---|
| 1 | `mi-scale` | 小米体重秤 v1、Mi Body Composition Scale v2、MI SCALE2 / MIBCS / MIBFS | BLE GATT | `00002a2f-…-0009af100700`；服务 `0x181B`/`0x181D` | 10B 历史帧、13B 实时帧；重量 LE uint16，kg /200，lb·斤 /100；bit5 稳定位、bit7 移除位；阻抗在 13B 帧偏移 9 |
| 2 | `yunmai` | 云麦好轻 Mini / SE / ISSE / SIGNAL / ISC2P / Scale-3 | BLE GATT | 测量 `0xFFE0/0xFFE4`，命令 `0xFFE5/0xFFE9` | 连接后必须写用户包、时间包、启动包；最终帧 `data[3] == 0x02`，时间戳 BE u32@5，重量 BE u16@13 /100 |
| 3 | `vscale` | Exingtech Y1、VScale 及同类 20B 方案 | BLE GATT | 服务 `f433bd80-75b8-11e2-97d9-0002a5d5c51b` | 20B，全 BE u16 /10：体重@4、体脂@6、水分@8、骨量@10、肌肉@12；`data[6]==0xFF` 为仅体重帧需等待 |
| 4 | `qn-scale` | QN Scale 方案：FITINDEX、Renpho、香山、1byone、Etekcity、部分乐心 | BLE GATT | Type1 `0xFFE0/0xFFE1`，Type2 `0xFFF0/0xFFF1` | opcode `0x10` 帧：重量 BE u16@3、稳定位@5、阻抗@6；ES-30M 变体稳定位@4、重量@5；缩放系数 /100 与 /10 启发式回退 |
| 5 | `broadcast-scale` | 三诺 Sinocare、IFIT 及通用广播方案 | **纯广播，无需连接** | 广播名 `Weight Scale`/`IFIT`，或厂商数据帧校验通过 | Manufacturer Data >16B，重量高字节@10、低字节@9（/100 kg），XOR[6..15] 校验 == data[16]；连续 9 帧相同才判定锁定 |
| 6 | `scales-bridge-text` | 串口电子秤 + BLE 透传模块（HC-08/JDY/BT05/Nordic UART） | BLE 透传 / SPP 语义 | `0xFFE0/0xFFE1`、`0xFFF0/0xFFF1`、`6e400001` | 18B ASCII 定长帧（0x0A…0x0D）与协议 C（`=` 终止）；内置拆包粘包缓冲与正则兜底 |
| 7 | `standard` | 任意符合 SIG 标准的体重秤（Beurer、Medisana、华为生态等） | BLE GATT | 服务 `0x181D`/`0x181B`/`0x181C`/`0x1805` | `0x2A9D` Flags + 重量（SI 0.005kg / Imperial 0.01lb）+ 可选时间戳/UserID/BMI/Height；`0x2A9C` 体成分 |

优先级顺序即上表顺序：厂商专有协议先匹配，标准协议兜底。
注册表见 `entry/src/main/ets/common/service/ProtocolRegistry.ets`。

**覆盖范围说明**：市售蓝牙秤绝大多数使用上述 7 类方案之一，尤其 QN（国产出海体脂秤主流方案）
与芯海/Chipsea 广播方案。但「适配」指协议层实现完成，**未做真机联调**。
部分厂商固件存在私有变体，可能需要按实际抓包微调字节偏移；扩展方式见第 5 节。

---

## 4. 架构

```
entry/src/main/ets/
├── entryability/EntryAbility.ets          应用入口
├── pages/Index.ets                        ArkUI 四页签界面（测量/趋势/设备/我的）
└── common/
    ├── model/ScaleModels.ets              统一数据模型（WeightReading / UserProfile / WeightRecord）
    ├── util/
    │   ├── ByteUtils.ets                  大小端读取、ASCII、CRC16、字节拼接
    │   └── BmiCalculator.ets              BMI、中国/WHO 分级、理想体重、体成分估算、单位换算
    ├── service/
    │   ├── ProtocolAdapter.ets            适配器接口（matchDevice / onServicesDiscovered / onNotification / onAdvertisement / onConnected）
    │   ├── ProtocolRegistry.ets           适配器注册与自动识别
    │   ├── StandardWeightProfileAdapter.ets
    │   ├── MiScaleAdapter.ets
    │   ├── YunmaiAdapter.ets
    │   ├── QNScaleAdapter.ets
    │   ├── VScaleAdapter.ets
    │   ├── BroadcastScaleAdapter.ets
    │   ├── ScalesBridgeTextAdapter.ets
    │   ├── ScaleBluetoothService.ets      BLE 扫描/连接/订阅/读写 + 广播 AD 结构解析
    │   └── ScaleDataStore.ets             preferences 本地持久化
    └── viewmodel/ScaleViewModel.ets       状态编排（蓝牙 → 协议 → BMI → 存储 → UI）
```

**数据流**：
```
BLE 扫描 ──┬─→ 广播型秤 ──→ onAdvertisement ──┐
           └─→ GATT 连接 ─→ notify ─→ onNotification ─┤
                                                     ├─→ WeightReading ─→ BMI/体成分 ─→ WeightRecord ─→ preferences ─→ UI
                                      手动录入 ──────┘
```

**关键设计**：
1. **统一输出模型** `WeightReading`，所有协议内部一律换算为 kg，展示时才按用户偏好转 lb/st。
2. **可插拔适配器**：新增厂商只实现 `ProtocolAdapter` 并在 `createDefaultAdapters()` 注册，连接层与 UI 零改动。
3. **广告数据自解析**：直接解析 `ScanResult.data` 的标准 AD 结构，不依赖 API 22+ 的便利字段，兼容到 HarmonyOS 5.x。
4. **稳定性判定**：协议层的稳定位、连续重复帧计数、同分钟去重三重过滤，避免抖动值入库。
5. **隐私**：无网络权限，数据仅存本机 preferences。

---

## 5. 扩展新协议

1. 在 `entry/src/main/ets/common/service/` 新建 `XxxAdapter.ets`，实现 `ProtocolAdapter`：

```ts
export class XxxAdapter implements ProtocolAdapter {
  readonly id: string = 'xxx';
  readonly displayName: string = '某某体脂秤';

  matchDevice(name: string, uuids: string[], msd: Uint8Array, sd: Uint8Array): boolean {
    return name.toUpperCase().indexOf('XXX') === 0;
  }
  onServicesDiscovered(services: ServiceRef[]): string[] {
    return []; // 返回需订阅的 characteristicUuid
  }
  onNotification(uuid: string, data: Uint8Array): WeightReading | null {
    // 解析字节帧，返回统一读数；无效帧返回 null
    return null;
  }
}
```

2. 在 `ProtocolRegistry.ets` 的 `createDefaultAdapters()` 加一行，给一个合适的 `priority`。
3. 在 `scripts/verify-protocols.cjs` 加一组样例帧断言（输入 hex → 期望 kg）。
4. `node scripts/verify-protocols.cjs && bash scripts/build.sh`。

若设备是**广播型**（不连接 GATT），额外实现 `requiresConnection(): false` 与
`onAdvertisement(...)`，并在 `ScaleViewModel` 构造函数的 `broadcastAdapters` 列表中注册。

---

## 6. 实现过程中的关键结论（踩过的坑）

这部分对后续维护比代码本身更重要：

1. **ArkTS 严格语法**：禁止内联对象字面量类型（`{ id: string }`）与无类型对象字面量，
   必须定义具名 `interface`。初次编译时 20 个错误中的 14 个来自此项。
2. **类型检查只在模块被引用时生效**：早期只写了 service 层、UI 尚未引用它们时，
   `CompileArkTS` 不会检查这些文件，刻意注入的类型错误也能「构建成功」。
   因此**必须以完整 UI 引用后的编译结果为准**。
3. **`BLEDeviceFind` 回调参数是 `Array<ScanResult>`**，不是单个 `ScanResult`。
4. **`BLEConnectionStateChange` 回调是 `BLEConnectionChangeState` 对象**，
   `state` 为 `ProfileConnectionState` 枚举（0 断开 / 1 连接中 / 2 已连接 / 3 断开中），不是字符串。
5. **`ScanResult` 的字段名**：`deviceId`、`deviceName`、`rssi`、`data` 是基础字段；
   `serviceUuids`、`manufacturerDataMap`、`serviceDataMap` 是 **API 22+** 才有的便利字段。
   本项目改为自解析 `data`，并因此消除全部 SDK 版本兼容警告。
6. **特征属性是 `GattProperties` 布尔字段**（`write` / `notify` / `indicate`），
   不存在 `PropertyType` 枚举；`ble.SCAN_MODE_LOW_LATENCY` 需写作 `ble.ScanDuty.SCAN_MODE_LOW_LATENCY`。
7. **`GET_BLUETOOTH_PEERS_MAC` 是 system_basic 级权限**，三方应用无法申请；
   API 26 起未持该权限时系统返回虚拟 MAC。因此应用不应把 MAC 当作跨会话稳定标识。
   本项目只把 MAC 存作「上次连接提示」，不影响功能。
8. **工程路径不可含中文**：hvigor 报 `00306003 Specification Limit Violation`，故引入构建脚本做 ASCII 路径中转。
9. **打包阶段依赖 `java`**：需把 DevEco 自带 JBR 加入 PATH，否则 `PackageHap` 报 `spawn java ENOENT`。
10. `Circle.fill` 是 API 26 新接口，已改用基础 `Row + borderRadius` 实现圆点。

以下为第二轮「界面与档案」修复中定位到的问题，其中 11–14 共同造成「个人档案填写无反应」：

11. **ViewModel 不是响应式对象**。`ScaleViewModel` 是普通 class（非 `@Observed`），
    ArkUI 无法追踪其内部字段；早期用 `refreshTick += 1` 驱动刷新，但该变量**没有在 build 中被任何节点读取**，
    依赖根本没建立，保存档案后整页不重绘。现改为把 VM 快照放进 `@State view: ScaleViewState`，
    每次 `notifyChange()` 都换一个新对象引用，所有读取 `view.vm.*` 的节点必然重算。
    > 补充：ArkUI 按节点追踪状态依赖，单个「不可见状态锚点 Text」只能刷新它自己，不能保证其它节点重绘。
12. **`@Builder` 基本类型按值传参**。旧的 `SettingSlider('身高', ..., this.formHeight, ...)` 中
    `value` 是快照，拖动滑块后数值文本不会更新。档案表单已改为 `TextInput` 直接绑定 `@State` 字符串，
    并去掉数值型 `@Builder` 传参。
13. **`promptAction.showToast` 与 `getContext` 均已废弃**（API 26 编译警告）。
    提示不弹出会让用户以为「点了没反应」。现改用 `UIContext.getPromptAction().showToast()`；
    UIAbility 上下文由 `EntryAbility.onCreate` 存入 `AppStorage`，页面从 `AppStorage` 取用，
    不再依赖 UIContext 挂载时机。
14. **存储层静默失败**。`ScaleDataStore.saveProfile()` 在 `preferences` 未初始化时直接 `return`，
    档案保存失败毫无提示。现改为返回 `boolean`，`ScaleViewModel.updateProfile()` 透传结果，
    UI 在失败时保留编辑页并显示红色错误提示；`saveRecords()` 同样不再静默。
15. **`InputType.Number` 不支持小数点**（SDK 明确注释「Negative numbers and decimals are not supported」）。
    手动录入改用 `InputType.NUMBER_DECIMAL` + `inputFilter('^\\d{0,3}(\\.\\d{0,2})?$')`，
    提交时按 0.01 kg 精度取整，并按当前展示单位换算后入库。
16. **底部页签的两种形态**：官方规范（bottomtab V15）中平铺式默认 48vp、悬浮式 56vp 胶囊，
    控件默认会避让系统导航条。曾按用户要求实现悬浮式（56vp 胶囊、28vp 圆角、最大宽 328vp），
    第四轮按「取消悬浮栏」要求回退为**平铺式**：整宽贴底、纯色底 + 顶部 1vp 分隔线，
    内容区用 `Column` + `layoutWeight(1)` 与页签栏上下分区，不再有 `Stack` 叠层、模糊、
    阴影与底部渐变蒙层；滚动内容底部留白由 104vp 回到 16vp。
    第六轮按「图标太小 / 大色块胶囊选中」把栏高由 48vp 提到 56vp（沿用规范悬浮式的既有
    数值，布局仍是平铺贴底）、图标由 24vp 放大到 28vp、选中项改为 48vp 高半圆角实心胶囊。
    「胶囊」只指选中态色块，不是把整条栏重新悬浮；四个页签都用同尺寸胶囊占位，
    切换时只变背景与前景色，图标文字位置不跳动。
17. **沉浸光感材质仅在悬浮态有意义**：规范（immersivelight V1「场景规范」）推荐底部悬浮组件用
    `THIN` 档，SDK 对应 `BlurStyle.COMPONENT_THIN`（不是旧版 `BlurStyle.Thin`）；
    系统自动把用户三档强度映射到该枚举。改平铺式后整套材质已移除。保留结论：
    `backgroundBlurStyle` 自带 mask color / opacity / 亮度 / 饱和度，额外底色只能用 20% 白，
    过实会盖住透射感；若日后恢复悬浮式，装饰层用 `HitTestMode.None`、容器用 `Transparent`。
18. **放大 Path 图标不能改组件宽高**：`Path.commands` 用的是绝对坐标，把 `width/height`
    从 24 改成 28 只会放大画布、图形仍按 24 坐标绘制且偏左上。正确做法是保持 24vp 组件，
    用 `.scale({ x: 1.2, y: 1.2 })` 以自身中心缩放 → 视觉 28.8vp，描边同比加粗。
    悬浮式规范明确「不支持横滑内容切换页签」，因此去掉 `Tabs/TabContent`，
    改由 `@State currentTab` 条件渲染四个页（平铺式沿用该结构）。
    第六轮改用系统 `SymbolGlyph` 后尺寸由 `.fontSize(28)` 直接控制，不再需要 scale；
    上述技巧只保留在 `DOCK_USE_SYSTEM_SYMBOL = false` 的自绘回退分支。
19. **设备页空状态与状态反馈**：`access.getState()`（`@kit.ConnectivityKit`，API 10+）读取系统
    蓝牙开关，`STATE_ON=2` / `STATE_BLE_ON=5` 视为可用；`bluetooth.getState()` 已废弃。
    该调用可能因权限或服务未就绪抛错，必须 try/catch 降级为「未知」，且每次进入设备页
    用 `onAppear` 重读。扫描按钮用 `LoadingProgress` + 「搜索中…」表达进行态并支持再次点击停止。
    两列品牌标签用 `string[][]` 两两分组 + `Row` 渲染，避免引入 `Flex`/`Grid` 的兼容不确定性；
    协议全名与品牌短名分离（`AdapterInfo.shortName`），窄空间只显示短名。
20. **应用图标必须分层**：规范（application-icon V17）要求前景/背景双层 1024² PNG、
    背景层不得含透明像素、主体居中远离四角。`layered_image.json` 放在 `media/` 目录，
    由 `module.json5` 的 `abilities[].icon` 指向 `$media:layered_image`；
    启动窗口必须用单层不透明 PNG（`startIcon.png`）。配色由 `scripts/gen-icons.cjs` 的
    `SOLID_COLORS` 控制（第五轮按用户要求取消全部渐变，底板为单一纯色 `#0D7377`，
    这一项刻意偏离官方「上浅下深」建议），换色后需同步 `COLOR_BRAND` 并复核白色前景对比度。
21. **系统 Symbol 图标名必须来自 SDK 资源表**：HarmonyOS 内置图标用
    `SymbolGlyph($r('sys.symbol.xxx'))` 引用，全量名称在
    `sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js` → `sys.symbol`
    （本 SDK 共 4042 个），官方「HarmonyOS 主题图标库」可在线浏览预览。
    hvigor 在 `CompileArkTS` 阶段逐个校验，写错会直接报 `Unknown resource name 'xxx'`：
    本项目第一次用 `chart_bar` 被拦下，换成表中确实存在的 `histogram` 后通过。
    最终四个页签用 `body_fat_scale` / `histogram` / `bluetooth` / `person`，
    均为语义贴合的系统默认图标（含体脂秤专用符号），不打包进 HAP。
    单色渲染 `renderingStrategy(SINGLE)` + `fontColor([...])` 上色，
    `BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.DOWN)` 实现规范推荐的选中弹跳。
    低版本系统 ROM 若缺某个新符号，把 `Index.ets` 的 `DOCK_USE_SYSTEM_SYMBOL` 置 false
    即整体回退到自绘 Path 图标。
22. **主题色运行时切换不能用 const**：`COLOR_BRAND` 这类编译期常量无法随用户选择变化。
    改用 `@StorageLink('theme_color')` 暴露为组件 `@State` 字段，配合 preferences 持久化索引；
    浅底（`themeColorSoft`）、扫描环透明度（`themeRing/themeRingInner/themeCore`）由
    主题色 hex 追加 alpha 前缀动态拼出（`#AARRGGBB`，如 `#22` + `0D7377`）。
    `Stack` 不能用 `justifyContent` 居中，须用 `alignContent(Alignment.Center)`；
    `Circle().fill()` 在 API 20 兼容基线会告警，色块改用 `Row` + `borderRadius` + `backgroundColor`。
23. **「选中后图标变实心」用 *_fill 变体实现**：未选中用描边线稿（如 `body_fat_scale`），
    选中切换到同义 `_fill` 实心符文（`body_fat_scale_fill` / `histogram_fill` / `person_fill`）；
    `bluetooth` 无 fill 变体，选中以白符文占位同样呈实心观感。`*_fill` 名称同样须过编译期资源表校验。
24. **新增 Symbol 前先查表，勿凭直觉命名**：设备页右上角「重新扫描」最初写成
    `sys.symbol.refresh`，该名称在 4042 项资源表中并不存在，`CompileArkTS` 直接报
    `Unknown resource name 'refresh'`（**编译期失败**，并非运行时缺图）。改为表中确有的
    `arrow_clockwise`（顺时针循环箭头）后通过。快速核验：
    `node -e "const s=require('.../sysResource.js').sys; console.log('arrow_clockwise' in s.symbol)"`。
25. **全局 `animateTo` 在 API 26 已废弃**：扫描波纹定时器里直接调用会产生
    `ArkTS:WARN 'animateTo' has been deprecated`。改用
    `this.getUIContext().animateTo({ duration, curve }, () => {...})`（与 toast 所用
    `this.getUIContext().getPromptAction()` 同一 UIContext 入口），告警消除。

---

## 7. 功能与限制

**已实现**
- BLE 扫描、设备自动识别与协议匹配、GATT 连接/服务发现/通知订阅/写命令
- 7 类协议解析（含广播型与串口透传），统一 kg 内部表示，kg/lb/st 展示
- BMI 计算、中国标准（18.5 / 24 / 28）与 WHO 标准（18.5 / 25 / 30）分级
- 理想体重区间、目标体重建议、体脂/肌肉/水分/骨量估算
- 历史记录（同分钟去重、最多 2000 条）、Canvas 折线趋势图、CSV 导出到剪贴板
- 手动录入（支持两位小数、按展示单位换算）、用户档案本地持久化、身高变更后历史 BMI 自动重算
- **「我的」模块**：个人中心头部、档案摘要、数据概览（累计次数/最近体重/BMI/距目标）、
  功能入口（编辑档案 / 导出 CSV / 查看适配协议 / 清空记录）；档案编辑为页内子页
- 中国标准 / WHO 标准可切换并即时影响 BMI 分级与历史记录重算
- 平铺式底部页签：56vp 栏高、HarmonyOS 系统 Symbol 22vp 图标、**选中切换为 *_fill 实心符文**、
  品牌色实心胶囊选中态与 `BounceSymbolEffect` 弹跳反馈；一行开关可回退到自绘 Path 图标
- **主题色可选**：「我的」页内置「中国式传统颜色」色板（黛绿/朱砂/石青/竹青/绛紫/群青/赭石/黛蓝），
  点击即时换色并持久化；应用内强调色（按钮、选中胶囊、图表、Tag、信号格、蓝牙状态）随之联动；
  **底部页签图标也跟随主题色变化**（未选中项图标直接取主题强调色），切换主题时图标同步变色；
  下次启动仍生效（存于 preferences）
- **自定义圆形头像（可裁剪）**：「我的」页与档案编辑页头像点击从相册选图（PhotoViewPicker），
  进入裁剪页后**可拖动选框调整位置、滑块调整裁剪尺寸**（`@ohos.multimedia.image` 的 `PixelMap.crop`
  + `ImagePacker` 打包为 jpg 存入沙箱），裁剪结果持久化为 `UserProfile.avatarUri`；
  无自定义头像时显示主题色占位人形，右下角相机角标提示可点击更换
- **个人信息分组**：「我的」页头部与档案编辑页均增加「个人信息」二级标题，头像与昵称归入该分组下
- **应用内品牌图标跟随主题色**：新增 `AppLogo`（主题色圆角方块 + 白色体脂秤符文），用于「关于应用」页，
  切换主题色时同步变化
- **关于 / 隐私 / 开源介绍**：「我的」页新增「关于」卡片，含「关于应用 / 隐私说明 / 开源声明」三个入口，
  点击进入详情子页（隐私说明明确「数据仅本机、不上传」；开源介绍说明灵感来自 scales-bridge 与 openScale、
  协议层为 ArkTS 自研）
- 纯色分层应用图标，三套可切换纯色（默认「青屿」青绿 `#0D7377`），白色前景对比度 5.5:1；
  **桌面启动图标为静态资源，无法运行时改色**——如需让它匹配所选主题色，修改 `scripts/gen-icons.cjs`
  的 `PALETTE` 后重跑脚本并重新签名打包即可

**限制（明确说明）**
- **未做真机联调**。所有协议均按开源实现与规范文档实现，并通过构造帧的单元验证；
  真实设备固件可能存在变体，需按抓包结果微调。
- **系统 Symbol 图标未实机确认**。四个名称已通过 DevEco SDK 资源表的编译期校验，
  但低版本系统 ROM 是否内置 `body_fat_scale` / `histogram` 需真机核对；
  若不渲染，把 `Index.ets` 的 `DOCK_USE_SYSTEM_SYMBOL` 改为 `false` 即回退自绘图标。
- **底部页签的大色块为自定义偏离**。栏高 56vp、图标 22vp、选中态实心胶囊是按用户明确要求实现，
  与 bottomtab V15 平铺式默认 48vp / 24vp / 10vp 不同；弹跳动效、深色模式与导航条避让未做实机评审。
- **体成分估算不是测量值**。无阻抗数据时采用 Deurenberg 公式变体，误差约 ±3–5%；
  设备上报的阻抗目前仅存储，未接入小米/云麦的厂商体成分算法。
- **小米历史数据同步、UDS 多用户管理、时间同步 ACK** 未完整实现，当前以实时测量帧为主。
- **RFCOMM/SPP 未实现**：HarmonyOS 的 `@ohos.bluetooth.socket` 需单独适配；
  串口秤需通过 BLE 透传模块使用第 6 类适配器。
- **桌面启动图标无法运行时改色**。鸿蒙第三方应用不能在运行时修改桌面图标，它随 HAP 静态打包；
  应用内展示的品牌标识（`AppLogo`）可跟随主题色，但桌面图标不变。如需一致，按上文改 `PALETTE` 重生成。
- **头像裁剪、关于/隐私/开源页、主题色联动 AppLogo 均未实机验证**：`PixelMap.crop`、沙箱 jpg 写入、
  `Image(PixelMap)` 渲染与圆形裁剪、以及子页跳转观感需在真机核对；安装前仍需配置签名。
- HAP 未签名，需配置签名后安装。
- 档案使用 `TextInput` 精确输入 + `Select` 选择（不再使用滑块），数值范围在保存时校验：
  身高 50–250 cm、年龄 1–120、目标体重 20–300 kg。

**医学声明**：BMI 与身体成分为健康参考与估算值，不能替代医疗诊断。

---

## 8. 许可与来源说明

- 本项目代码为新建实现，协议字节格式参考自 GPL-3.0 的 openScale 与 MIT/自述许可的 scales-bridge。
  若分发二进制，请注意 GPL-3.0 的传染性条款，或仅参考格式规范重新实现。
- 未复制上述项目的源码文件；`_ref/` 目录仅为本地调研用的只读克隆，不属于应用工程。
