/**
 * 轻秤 —— 鸿蒙体重管理应用主界面
 *
 * 页面结构（底部页签 4 个，符合鸿蒙「一般选择 4 个以下」的规范）：
 *   测量 / 趋势 / 设备 / 我的
 *
 * 设计规范遵循（design-guides 官方原文核对）：
 * - 底部页签 V15「平铺式」：整宽贴底、顶部 1vp 分隔线与内容分区，
 *   无悬浮栏、无模糊材质、无投影；页签栏与内容区上下分区，内容不被遮挡。
 * - 按用户约定取消上一版的沉浸光感悬浮 dock：移除离底边距、容器胶囊、
 *   COMPONENT_THIN 材质、柔光阴影与底部渐变蒙层。本轮「胶囊」仅指**选中项色块**，
 *   不是把整条导航重新悬浮起来。
 * - HarmonyOS Symbol V16：系统内置图标库，用 SymbolGlyph($r('sys.symbol.xxx')) 引用；
 *   图标尺寸与字号一致，支持 fontColor / renderingStrategy / 动效。
 * - bottomtab V15「视觉反馈」推荐切换选中态使用 BounceSymbolEffect(EffectDirection.DOWN)。
 * - 不用 Tabs 承载内容，改为按状态条件渲染四个页，避免横滑切换与页签冲突。
 *
 * 本轮的自定义偏离（按用户明确要求，非规范默认值）：
 * - 图标 24vp → 22vp（规范平铺式默认 24*24vp），标签 10vp → 12fp；
 * - 栏高 48vp → 56vp，取自规范「悬浮式 56vp」这一既有数值，给大色块留空间，
 *   布局仍是平铺贴底；胶囊圆角取半高 24vp，与规范 56vp 胶囊 28vp 圆角同一规则；
 * - 选中态从品牌高亮文字改为品牌色实心胶囊（白字 + 实心符文，对比度 ≥4.5:1）；
 *   未选中为灰色描边线稿，选中切换为 *_fill 实心符文（蓝牙无 fill 变体，以白符文替代）。
 * - 热区仍 ≥48vp×48vp，四个页签均分宽度。
 * - 主题色可选「中国式传统颜色」，应用内强调色（按钮/胶囊/图表）随之切换，持久化于本地。
 * - 屏幕左右边距 16vp，卡片内边距 16vp，卡片圆角 16vp。
 * - 展示级字号 56fp（体重）、38fp（BMI）、标题 20fp、正文 16fp、辅助 12fp。
 * - 交互热区 ≥48vp 高，按钮圆角 20vp；正文文字对比度 ≥4.5:1。
 */

import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { BmiStandardChoice, Gender, UserProfile, WeightRecord, WeightUnit } from '../common/model/ScaleModels';
import { convertToKg } from '../common/util/BmiCalculator';
import { DeviceItem, ScaleViewModel } from '../common/viewmodel/ScaleViewModel';
import { BtConnectionState } from '../common/service/ScaleBluetoothService';
import { AdapterInfo } from '../common/service/ProtocolRegistry';

const SCREEN_PADDING: number = 16;
const CARD_RADIUS: number = 16;
const BUTTON_HEIGHT: number = 48;
/**
 * 平铺式底部页签：栏高沿用规范「悬浮式 56vp」数值（仅取尺寸，不取悬浮形态）。
 * 选中项胶囊 48vp 高、圆角 24vp（半高胶囊），左右各留 4vp 安全间隔。
 */
const DOCK_HEIGHT: number = 56;
const DOCK_PILL_HEIGHT: number = 48;
/** dock 胶囊左右内边距：与页面卡片边距 SCREEN_PADDING 保持一致 */
const DOCK_PILL_MARGIN: number = SCREEN_PADDING;
/** 系统 Symbol 用 fontSize 直接控制，22vp（比上一轮 28vp 再小，避免手机上显得拥挤）；标签 12fp 协调 */
const DOCK_ICON_SIZE: number = 22;
const DOCK_LABEL_SIZE: number = 12;
/**
 * 系统 Symbol 开关。true = 使用 HarmonyOS 内置图标（推荐，可带动效）；
 * false = 回退到本地自绘 Path 线稿。若真机上某个 sys.symbol 名称不渲染，
 * 改这一行即可整体回退，无需改动页面结构。
 */
const DOCK_USE_SYSTEM_SYMBOL: boolean = true;
/** 仅回退分支使用：24vp 线稿放大 1.2 倍 → 视觉 28.8vp */
const DOCK_ICON_SCALE: number = 1.2;
/** 页签栏与内容区上下分区，滚动到底只需常规底部留白 */
const SCROLL_BOTTOM_PADDING: number = SCREEN_PADDING;
const COLOR_BG: string = '#F5F6F8';
const COLOR_CARD: string = '#FFFFFF';
const COLOR_PRIMARY_TEXT: string = '#182431';
const COLOR_SECONDARY_TEXT: string = '#4D5A6B';
const COLOR_TERTIARY_TEXT: string = '#7A8699';
/** 选中胶囊内的图标/文字：白字，配合任一传统色均满足对比度 ≥4.5:1 */
const COLOR_DOCK_ON: string = '#FFFFFF';
const COLOR_DIVIDER: string = '#E5E8ED';
/** 警示色（蓝牙关闭） */
const COLOR_WARN: string = '#C4261D';
const COLOR_TAG_MUTED: string = '#F2F3F5';
const COLOR_BAR_OFF: string = '#D8DEE5';

/**
 * 「中国式传统颜色」主题色板。用户可在「我的」页切换，应用内强调色随之改变。
 * 均为深色调，与白字（按钮 / 选中胶囊）对比度 ≥4.5:1，保证可读性。
 * 索引 0 为默认（黛绿），与启动图标纯色底板一致。
 */
interface ThemeColor {
  name: string;
  hex: string;
}
const THEME_COLORS: Array<ThemeColor> = [
  { name: '黛绿', hex: '#0D7377' },
  { name: '朱砂', hex: '#C3272B' },
  { name: '石青', hex: '#11708F' },
  { name: '竹青', hex: '#3E7C5A' },
  { name: '绛紫', hex: '#8C4356' },
  { name: '群青', hex: '#2E6E9E' },
  { name: '赭石', hex: '#9C5333' },
  { name: '黛蓝', hex: '#426666' }
];
const DEFAULT_THEME_INDEX: number = 0;
/** 「支持的设备品牌」默认展示数量，展开后显示全部 */
const BRAND_PREVIEW_COUNT: number = 4;

/** 底部页签线稿图标（24vp 坐标系，描边路径） */
const ICON_MEASURE: string = 'M4 3 H20 A1 1 0 0 1 21 4 V20 A1 1 0 0 1 20 21 H4 A1 1 0 0 1 3 20 V4 A1 1 0 0 1 4 3 Z M7 7 H17 M8 17 A4 4 0 0 0 16 17';
const ICON_TREND: string = 'M3 17 L8 12 L12 15 L21 6 M16 6 H21 V11';
const ICON_DEVICE: string = 'M8 7 L16 17 L12 21 V3 L16 7 L8 17';
const ICON_MINE: string = 'M12 12 A4 4 0 1 0 12 4 A4 4 0 0 0 12 12 M4 21 C4 16.5 7.5 14 12 14 C16.5 14 20 16.5 20 21';

/**
 * ViewModel 快照。ScaleViewModel 不是 @Observed，ArkUI 无法追踪其内部字段；
 * 每次数据变更换一个新快照对象，@State 引用变化会让所有读取 view 的节点重绘。
 */
interface ScaleViewState {
  vm: ScaleViewModel;
  revision: number;
}

@Entry
@Component
struct Index {
  /** ViewModel 快照：引用变化即触发全部依赖节点重算 */
  @State private view: ScaleViewState = { vm: new ScaleViewModel(), revision: 0 };
  @State private currentTab: number = 0;
  @State private manualWeightInput: string = '';

  // 档案表单统一用字符串绑定 TextInput，避免 @Builder 基本类型按值传参导致输入不刷新
  @State private formHeight: string = '170';
  @State private formAge: string = '30';
  @State private formTarget: string = '65.0';
  @State private formNickname: string = '';
  @State private formGenderIndex: number = 0;
  @State private formUnitIndex: number = 0;
  @State private formBmiStandardIndex: number = 0;
  @State private editingProfile: boolean = false;
  @State private saveHint: string = '';
  @State private saveOk: boolean = true;
  /** 设备页：「支持的设备品牌」是否展开 */
  @State private brandsExpanded: boolean = false;
  /** 设备页：新用户操作提示是否可见 */
  @State private scanTipVisible: boolean = true;
  /** 扫描波纹动效状态：扫描期间由定时器翻转 waveOn，驱动两层同心圆向外扩散的雷达波纹 */
  @State private waveOn: boolean = false;
  private waveTimer: number = 0;
  /** 主题强调色（运行时可变，来自「我的」页选择；持久化于 preferences） */
  @StorageLink('theme_color') private themeColor: string = '#0D7377';

  /** 裁剪页是否打开（从相册选图后进入） */
  @State private croppingAvatar: boolean = false;
  /** 详情子页：关于 / 隐私 / 开源 */
  @State private detailPage: 'none' | 'about' | 'privacy' | 'opensource' = 'none';
  /** 待裁剪图像（源 PixelMap，仅裁剪页生命周期内有效） */
  @State private cropPixelMap: image.PixelMap | null = null;
  private cropSrcW: number = 0;
  private cropSrcH: number = 0;
  /** 显示画布尺寸（正方形），源图按 cover 适配后居中，裁剪框在画布坐标系内 */
  private readonly CROP_CANVAS: number = 300;
  private cropScale: number = 1;
  private cropOffX: number = 0;
  private cropOffY: number = 0;
  @State private cropBoxX: number = 0;
  @State private cropBoxY: number = 0;
  @State private cropBoxSize: number = 220;
  private panStartX: number = 0;
  private panStartY: number = 0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private chartCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private initialized: boolean = false;

  async aboutToAppear(): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    this.view.vm.setOnChange(() => {
      const current: ScaleViewState = this.view;
      const next: ScaleViewState = { vm: current.vm, revision: current.revision + 1 };
      this.view = next;
    });
    const context = AppStorage.get<common.UIAbilityContext>('app_ability_context');
    if (!context) {
      this.toast('应用上下文未就绪，请重启应用');
      return;
    }
    await this.view.vm.init(context);
    // 从持久化的主题色索引恢复应用强调色（默认黛绿）
    const saved: ThemeColor = THEME_COLORS[this.view.vm.themeColorIndex] ?? THEME_COLORS[DEFAULT_THEME_INDEX];
    this.themeColor = saved.hex;
    this.syncFormFromProfile();
    await this.view.vm.requestPermissions(context);
  }

  aboutToDisappear(): void {
    this.stopWaveLoop();
  }

  /** 从档案回写表单（仅初始化与保存后调用，不覆盖用户正在输入的内容） */
  private syncFormFromProfile(): void {
    const p = this.view.vm.profile;
    this.formHeight = `${p.heightCm}`;
    this.formAge = `${p.age}`;
    this.formTarget = p.targetWeightKg.toFixed(1);
    this.formNickname = p.nickname;
    this.formGenderIndex = p.gender === Gender.FEMALE ? 1 : 0;
    this.formUnitIndex = p.displayUnit === WeightUnit.LB ? 1 :
      (p.displayUnit === WeightUnit.ST ? 2 : 0);
    this.formBmiStandardIndex = p.bmiStandard === BmiStandardChoice.WHO ? 1 : 0;
  }

  build() {
    // 平铺式：内容区与页签栏上下分区，内容不再延伸到 dock 背后，
    // 因此无需 Stack、渐变蒙层与 hitTestBehavior 透传。
    Column() {
      // 1) 内容区：按状态条件渲染四个页
      Column() {
        if (this.currentTab === 0) {
          this.MeasureTab()
        } else if (this.currentTab === 1) {
          this.TrendTab()
        } else if (this.currentTab === 2) {
          this.DeviceTab()
        } else {
          this.MineTab()
        }
      }
      .width('100%')
      .layoutWeight(1)

      // 2) 平铺式页签栏：整宽贴底、纯色底 + 顶部分隔线，无悬浮与光感材质
      Row() {
        this.DockItem('测量', 0, ICON_MEASURE)
        this.DockItem('趋势', 1, ICON_TREND)
        this.DockItem('设备', 2, ICON_DEVICE)
        this.DockItem('我的', 3, ICON_MINE)
      }
      .width('100%')
      .height(DOCK_HEIGHT)
      .backgroundColor(COLOR_CARD)
      .border({ width: { top: 1 }, color: COLOR_DIVIDER })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_BG)
  }

  /**
   * HarmonyOS 系统内置 Symbol 图标（不是自绘图形，也不是打包进 HAP 的图片）。
   * 名称来自 DevEco SDK 的 ets-loader/sysResource.js → sys.symbol（约 4000 个），
   * 编译时 hvigor 会逐个校验，写错会直接报 "Unknown resource name"。
   * 也可在官方「HarmonyOS 主题图标库」查询：
   * https://developer.huawei.com/consumer/cn/design/harmonyos-symbol/
   *
   * body_fat_scale 体脂秤 / histogram 柱状趋势 / bluetooth 蓝牙设备 / person 个人。
   * 未选中用描边线稿（灰色）；选中切换为 *_fill 实心符文（白符文 + 主题色胶囊），
   * 实现「选中后图标变实心」。bluetooth 无 fill 变体，选中以白色符文占位同样呈实心观感。
   */
  private dockSymbol(index: number, selected: boolean): Resource {
    if (selected) {
      if (index === 0) {
        return $r('sys.symbol.body_fat_scale_fill');
      }
      if (index === 1) {
        return $r('sys.symbol.histogram_fill');
      }
      if (index === 2) {
        return $r('sys.symbol.bluetooth');
      }
      return $r('sys.symbol.person_fill');
    }
    if (index === 0) {
      return $r('sys.symbol.body_fat_scale');
    }
    if (index === 1) {
      return $r('sys.symbol.histogram');
    }
    if (index === 2) {
      return $r('sys.symbol.bluetooth');
    }
    return $r('sys.symbol.person');
  }

  /** 主题色浅底（Tag / 设备图标底 / 选中态柔光）；格式 #AARRGGBB */
  private themeColorSoft(): string {
    return '#22' + this.themeColor.slice(1);
  }

  /** 空状态同心圆描边（由外到内逐级加深的主题色低透明度） */
  private themeRing(): string {
    return '#1F' + this.themeColor.slice(1);
  }

  private themeRingInner(): string {
    return '#33' + this.themeColor.slice(1);
  }

  private themeCore(): string {
    return '#14' + this.themeColor.slice(1);
  }

  /** 待机态同心圆描边：比扫描态更低透明度，呈现轻盈的静态留白（避免红色/主题色过重） */
  private themeRingIdle(): string {
    return '#0D' + this.themeColor.slice(1);
  }

  private themeRingIdleInner(): string {
    return '#1A' + this.themeColor.slice(1);
  }

  /**
   * 应用内品牌图标（跟随主题色的圆角方块 + 白色体脂秤符文）。
   * 注意：桌面启动图标是打包进 HAP 的静态资源，第三方应用无法在运行时改色；
   * 这里提供的是应用内展示用的动态品牌标识，切换主题色会同步变化。
   */
  @Builder
  AppLogo(size: number) {
    Stack() {
      Row()
        .width(size)
        .height(size)
        .borderRadius(size * 0.28)
        .backgroundColor(this.themeColor)
      SymbolGlyph($r('sys.symbol.body_fat_scale'))
        .fontSize(size * 0.58)
        .fontColor([Color.White])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    }
    .width(size)
    .height(size)
  }

  /**
   * 大色块胶囊选中态：四个页签都用同尺寸胶囊占位，选中时只切换背景/前景色，
   * 图标与文字位置不随状态跳动；未选中项背景透明，仍是平铺式页签栏。
   * 选中胶囊底色与图标/文字统一为主题强调色（白），与任何传统色对比度均达标。
   */
  @Builder
  DockItem(label: string, index: number, fallbackCommands: string) {
    Column() {
      Column() {
        if (DOCK_USE_SYSTEM_SYMBOL) {
          SymbolGlyph(this.dockSymbol(index, this.currentTab === index))
            .fontSize(DOCK_ICON_SIZE)
            .fontWeight(FontWeight.Medium)
            // 选中图标为白色（落在主题色胶囊上）；未选中图标直接使用主题强调色，
            // 因此切换主题色时底部图标会同步变色，与「图标跟着颜色改」一致。
            .fontColor([this.currentTab === index ? COLOR_DOCK_ON : this.themeColor])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            // bottomtab V15 推荐的选中态弹跳反馈，仅在选中项激活
            .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.DOWN),
              this.currentTab === index)
        } else {
          // 回退：本地 24vp 线稿放大到 28.8vp
          Path({ width: 24, height: 24, commands: fallbackCommands })
            .fill(Color.Transparent)
            .stroke(this.currentTab === index ? COLOR_DOCK_ON : this.themeColor)
            .strokeWidth(2)
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
            .scale({ x: DOCK_ICON_SCALE, y: DOCK_ICON_SCALE })
        }
        Text(label)
          .fontSize(DOCK_LABEL_SIZE)
          .fontColor(this.currentTab === index ? COLOR_DOCK_ON : COLOR_SECONDARY_TEXT)
          .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
          .margin({ top: 2 })
      }
      .width('100%')
      .height(DOCK_PILL_HEIGHT)
      .borderRadius(DOCK_PILL_HEIGHT / 2)
      .backgroundColor(this.currentTab === index ? this.themeColor : Color.Transparent)
      .justifyContent(FlexAlign.Center)
    }
    .height(DOCK_HEIGHT)
    .layoutWeight(1)
    .padding({ left: DOCK_PILL_MARGIN, right: DOCK_PILL_MARGIN })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.currentTab = index;
    })
  }

  // ==================== 测量页 ====================
  @Builder
  MeasureTab() {
    Scroll() {
      Column({ space: 16 }) {
        Row() {
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.view.vm.connectionState === BtConnectionState.CONNECTED ? '#11823B' : '#8E8E93')
            .margin({ right: 8 })
          Text(this.view.vm.statusText)
            .fontSize(14)
            .fontColor(COLOR_SECONDARY_TEXT)
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(COLOR_CARD)
        .borderRadius(CARD_RADIUS)

        Column() {
          Text('当前体重')
            .fontSize(16)
            .fontColor(COLOR_SECONDARY_TEXT)
            .margin({ bottom: 8 })
          Row() {
            Text(this.view.vm.displayWeight())
              .fontSize(56)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_PRIMARY_TEXT)
            Text(this.view.vm.displayUnitSymbol())
              .fontSize(20)
              .fontColor(COLOR_SECONDARY_TEXT)
              .margin({ left: 8, top: 28 })
          }
          .alignItems(VerticalAlign.Bottom)

          if (this.view.vm.weightDeltaKg() !== null) {
            Text(this.deltaText())
              .fontSize(14)
              .fontColor(COLOR_SECONDARY_TEXT)
              .margin({ top: 8 })
          }

          Button(this.view.vm.scanning ? '停止扫描' : '扫描体重秤', { type: ButtonType.Capsule })
            .fontSize(16)
            .fontColor(Color.White)
            .backgroundColor(this.themeColor)
            .height(BUTTON_HEIGHT)
            .width('100%')
            .margin({ top: 20 })
            .onClick(() => {
              if (this.view.vm.scanning) {
                this.view.vm.stopScan();
              } else {
                this.currentTab = 2;
                this.view.vm.startScan();
              }
            })

          // 手动录入：NUMBER_DECIMAL 支持小数点，inputFilter 限制两位小数
          Row({ space: 8 }) {
            TextInput({
              placeholder: `手动输入体重 (${this.view.vm.displayUnitSymbol()})`,
              text: this.manualWeightInput
            })
              .type(InputType.NUMBER_DECIMAL)
              .inputFilter('^\\d{0,3}(\\.\\d{0,2})?$')
              .fontSize(16)
              .height(BUTTON_HEIGHT)
              .layoutWeight(1)
              .backgroundColor('#F7F8FA')
              .onChange((v: string) => {
                this.manualWeightInput = v;
              })
            Button('记录', { type: ButtonType.Capsule })
              .fontSize(16)
              .fontColor(this.themeColor)
              .backgroundColor('#E8F0FF')
              .height(BUTTON_HEIGHT)
              .onClick(() => {
                this.submitManualWeight();
              })
          }
          .width('100%')
          .margin({ top: 12 })

          Text('可输入两位小数，例如 65.25；录入值按所选单位换算后以 kg 存储')
            .fontSize(12)
            .fontColor(COLOR_TERTIARY_TEXT)
            .width('100%')
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(20)
        .backgroundColor(COLOR_CARD)
        .borderRadius(CARD_RADIUS)
        .alignItems(HorizontalAlign.Start)

        this.BmiCard()
        this.CompositionCard()
      }
      .width('100%')
      .padding({
        left: SCREEN_PADDING,
        right: SCREEN_PADDING,
        top: SCREEN_PADDING,
        bottom: SCROLL_BOTTOM_PADDING
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  BmiCard() {
    Column() {
      Row() {
        Text('BMI 身体质量指数')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PRIMARY_TEXT)
          .layoutWeight(1)
        Text(this.view.vm.bmiClassification().label)
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(this.view.vm.bmiClassification().color)
          .borderRadius(10)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      }
      .width('100%')

      Row() {
        Text(this.view.vm.currentBmi().toFixed(1))
          .fontSize(38)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_PRIMARY_TEXT)
        Text('kg/m²')
          .fontSize(14)
          .fontColor(COLOR_SECONDARY_TEXT)
          .margin({ left: 8, top: 22 })
      }
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 12 })

      this.BmiScaleBar()

      Row() {
        Text('理想体重')
          .fontSize(14)
          .fontColor(COLOR_SECONDARY_TEXT)
          .layoutWeight(1)
        Text(this.view.vm.idealWeightText())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PRIMARY_TEXT)
      }
      .width('100%')
      .margin({ top: 16 })

      Text(this.view.vm.adviceText())
        .fontSize(14)
        .fontColor(COLOR_SECONDARY_TEXT)
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  BmiScaleBar() {
    Column() {
      Row() {
        Column().width('25%').height(8).backgroundColor('#4A90D9')
        Column().width('30%').height(8).backgroundColor('#34C759')
        Column().width('20%').height(8).backgroundColor('#FF9F0A')
        Column().width('25%').height(8).backgroundColor('#FF3B30')
      }
      .width('100%')
      .borderRadius(4)
      .margin({ top: 16 })

      Row() {
        Text('偏瘦').fontSize(12).fontColor(COLOR_TERTIARY_TEXT)
        Text('正常').fontSize(12).fontColor(COLOR_TERTIARY_TEXT)
        Text('超重').fontSize(12).fontColor(COLOR_TERTIARY_TEXT)
        Text('肥胖').fontSize(12).fontColor(COLOR_TERTIARY_TEXT)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .margin({ top: 4 })

      Text(`当前 ${this.view.vm.currentBmi().toFixed(1)}  ·  ${this.view.vm.bmiStandardText()}`)
        .fontSize(12)
        .fontColor(COLOR_TERTIARY_TEXT)
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
  }

  @Builder
  CompositionCard() {
    Column() {
      Text('身体成分估算')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_PRIMARY_TEXT)
        .width('100%')
      Text('基于体重、身高、年龄与性别的估算值，非设备测量值')
        .fontSize(12)
        .fontColor(COLOR_TERTIARY_TEXT)
        .width('100%')
        .margin({ top: 4, bottom: 12 })

      GridRow({ columns: 2, gutter: { x: 12, y: 12 } }) {
        GridCol() {
          this.MetricTile('体脂率', this.bodyFatText())
        }
        GridCol() {
          this.MetricTile('骨骼肌', this.muscleText())
        }
        GridCol() {
          this.MetricTile('去脂体重', this.leanMassText())
        }
        GridCol() {
          this.MetricTile('身体水分', this.waterText())
        }
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MetricTile(label: string, value: string) {
    Column() {
      Text(label).fontSize(12).fontColor(COLOR_SECONDARY_TEXT)
      Text(value).fontSize(20).fontWeight(FontWeight.Medium)
        .fontColor(COLOR_PRIMARY_TEXT).margin({ top: 4 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F7F8FA')
    .borderRadius(8)
    .alignItems(HorizontalAlign.Start)
  }

  // ==================== 趋势页 ====================
  @Builder
  TrendTab() {
    Scroll() {
      Column({ space: 16 }) {
        Column() {
          Row() {
            Text('体重趋势')
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_PRIMARY_TEXT)
              .layoutWeight(1)
            Text(`${this.view.vm.records.length} 条记录`)
              .fontSize(12)
              .fontColor(COLOR_TERTIARY_TEXT)
          }
          .width('100%')

          if (this.view.vm.records.length > 0) {
            Canvas(this.chartCtx)
              .width('100%')
              .height(200)
              .margin({ top: 12 })
              .onReady(() => {
                this.drawChart();
              })
          } else {
            Column() {
              Text('暂无记录').fontSize(16).fontColor(COLOR_TERTIARY_TEXT)
              Text('连接体重秤测量，或在测量页手动录入')
                .fontSize(12)
                .fontColor(COLOR_TERTIARY_TEXT)
                .margin({ top: 6 })
            }
            .width('100%')
            .height(160)
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .padding(20)
        .backgroundColor(COLOR_CARD)
        .borderRadius(CARD_RADIUS)

        Column() {
          Text('测量记录')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PRIMARY_TEXT)
            .width('100%')
            .margin({ bottom: 8 })

          ForEach(this.view.vm.records, (r: WeightRecord) => {
            Row() {
              Column() {
                Text(`${r.weightKg.toFixed(2)} kg`)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(COLOR_PRIMARY_TEXT)
                Text(`${this.formatDate(r.timestamp)} · ${r.source}`)
                  .fontSize(12)
                  .fontColor(COLOR_TERTIARY_TEXT)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(`BMI ${r.bmi.toFixed(1)}`)
                .fontSize(14)
                .fontColor(COLOR_SECONDARY_TEXT)
              Button('删除')
                .fontSize(12)
                .fontColor('#C4261D')
                .backgroundColor(Color.Transparent)
                .height(40)
                .margin({ left: 8 })
                .onClick(() => {
                  this.view.vm.deleteRecord(r.id);
                })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .border({ width: { bottom: 1 }, color: COLOR_DIVIDER })
          }, (r: WeightRecord) => r.id.toString())
        }
        .width('100%')
        .padding(20)
        .backgroundColor(COLOR_CARD)
        .borderRadius(CARD_RADIUS)
      }
      .width('100%')
      .padding({
        left: SCREEN_PADDING,
        right: SCREEN_PADDING,
        top: SCREEN_PADDING,
        bottom: SCROLL_BOTTOM_PADDING
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  private drawChart(): void {
    const ctx = this.chartCtx;
    const records = this.view.vm.records.slice(0, 14).reverse();
    if (records.length === 0) {
      return;
    }
    const w = 320;
    const h = 200;
    const padL = 36;
    const padR = 12;
    const padT = 16;
    const padB = 28;
    ctx.clearRect(0, 0, w, h);

    let min = Number.MAX_VALUE;
    let max = Number.MIN_VALUE;
    for (const r of records) {
      if (r.weightKg < min) {
        min = r.weightKg;
      }
      if (r.weightKg > max) {
        max = r.weightKg;
      }
    }
    const span = Math.max(max - min, 2);
    const lo = min - span * 0.2;
    const hi = max + span * 0.2;
    const plotW = w - padL - padR;
    const plotH = h - padT - padB;

    ctx.strokeStyle = COLOR_DIVIDER;
    ctx.lineWidth = 1;
    ctx.font = '10px sans-serif';
    ctx.fillStyle = COLOR_TERTIARY_TEXT;
    for (let i = 0; i <= 3; i++) {
      const y = padT + plotH * i / 3;
      ctx.beginPath();
      ctx.moveTo(padL, y);
      ctx.lineTo(w - padR, y);
      ctx.stroke();
      ctx.fillText((hi - (hi - lo) * i / 3).toFixed(1), 2, y + 3);
    }

    ctx.strokeStyle = this.themeColor;
    ctx.lineWidth = 2;
    ctx.beginPath();
    const pointsX: number[] = [];
    const pointsY: number[] = [];
    for (let i = 0; i < records.length; i++) {
      const x = padL + (records.length === 1 ? plotW / 2 : plotW * i / (records.length - 1));
      const y = padT + plotH * (hi - records[i].weightKg) / (hi - lo);
      pointsX.push(x);
      pointsY.push(y);
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.stroke();

    ctx.fillStyle = this.themeColor;
    for (let i = 0; i < pointsX.length; i++) {
      ctx.beginPath();
      ctx.arc(pointsX[i], pointsY[i], 3, 0, 2 * Math.PI);
      ctx.fill();
    }

    ctx.fillStyle = COLOR_TERTIARY_TEXT;
    ctx.fillText(this.formatShortDate(records[0].timestamp), padL, h - 8);
    if (records.length > 1) {
      ctx.fillText(this.formatShortDate(records[records.length - 1].timestamp), w - padR - 32, h - 8);
    }
  }

  // ==================== 设备页 ====================
  /**
   * 信息架构（自上而下）：标题 + 蓝牙开关状态 + 状态化扫描按钮 → 引导副标题
   * → 扫描结果区（核心）→ 支持的设备品牌（辅助信息，页面最底部、可折叠）。
   * 无设备时用空状态插画填充中部留白，扫描到设备后由卡片列表自动替换。
   */
  @Builder
  DeviceTab() {
    Column({ space: 12 }) {
      // 1) 顶部：标题 + 蓝牙状态；右上角为轻量「刷新」图标（与中部主按钮区分），
      //    核心「开始/停止扫描」收拢到下方中部主按钮，避免功能重复
      Row() {
        Column() {
          Text('蓝牙体重秤')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PRIMARY_TEXT)
          Row() {
            Path({ width: 24, height: 24, commands: ICON_DEVICE })
              .fill(Color.Transparent)
              .stroke(this.bluetoothStateColor())
              .strokeWidth(2.2)
              .strokeLineCap(LineCapStyle.Round)
              .strokeLineJoin(LineJoinStyle.Round)
              .scale({ x: 0.6, y: 0.6 })
              .margin({ right: 2 })
            Text(this.bluetoothStateText())
              .fontSize(12)
              .fontColor(this.bluetoothStateColor())
          }
          .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 右上角改为轻量「重新扫描」图标：与中部主按钮区分，避免功能重复
        // 注意：SDK sys.symbol 表无 'refresh'，用 arrow_clockwise（顺时针循环箭头）
        Row() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(22)
            .fontColor([this.view.vm.scanning ? COLOR_TERTIARY_TEXT : this.themeColor])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(COLOR_CARD)
        .border({ width: 1, color: COLOR_DIVIDER })
        .enabled(!this.view.vm.scanning)
        .onClick(() => {
          if (this.view.vm.scanning) {
            return;
          }
          if (this.view.vm.bluetoothState === 'off') {
            this.toast('请先在系统设置中打开蓝牙');
            return;
          }
          this.scanTipVisible = false;
          this.view.vm.startScan();
          this.startWaveLoop();
        })
      }
      .width('100%')

      Text(this.deviceSubtitle())
        .fontSize(14)
        .fontColor(COLOR_SECONDARY_TEXT)
        .width('100%')

      Scroll() {
        Column({ space: 12 }) {
          // 2) 扫描结果区：用分区标题 + 数量与下方品牌说明明确区分
          Row() {
            Text('扫描结果')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_PRIMARY_TEXT)
            if (this.view.vm.devices.length > 0) {
              Text(`${this.view.vm.devices.length} 台设备`)
                .fontSize(12)
                .fontColor(COLOR_TERTIARY_TEXT)
                .margin({ left: 8 })
            } else if (this.view.vm.scanning) {
              Row() {
                LoadingProgress()
                  .width(12)
                  .height(12)
                  .color(this.themeColor)
                Text('搜索中')
                  .fontSize(12)
                  .fontColor(this.themeColor)
                  .margin({ left: 6 })
              }
              .margin({ left: 8 })
            }
          }
          .width('100%')

          if (this.view.vm.devices.length === 0) {
            this.EmptyScanState()
          } else {
            ForEach(this.view.vm.devices, (item: DeviceItem) => {
              this.DeviceCard(item)
            }, (item: DeviceItem) => item.deviceId)
          }

          // 3) 辅助信息：支持的设备品牌，默认 4 个短标签、两列网格，可展开
          this.BrandCard()
        }
        .width('100%')
        // 长列表滚动到底时，品牌卡片与底部页签栏之间保留安全边距
        .padding({ bottom: SCROLL_BOTTOM_PADDING + 8 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: SCREEN_PADDING,
      right: SCREEN_PADDING,
      top: SCREEN_PADDING,
      bottom: SCREEN_PADDING
    })
    .onAppear(() => {
      // 用户可能在系统设置里改过开关，每次进入设备页重新读取
      this.view.vm.refreshBluetoothState();
    })
  }

  /** 空状态：同心圆蓝牙搜索插画 + 引导文案 + 可关闭的悬浮操作提示 */
  @Builder
  EmptyScanState() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        // 静态同心圆：待机态低透明度（轻盈），扫描态增强对比
        Row()
          .width(184)
          .height(184)
          .borderRadius(92)
          .border({ width: 1.5, color: this.view.vm.scanning ? this.themeRing() : this.themeRingIdle() })
        Row()
          .width(140)
          .height(140)
          .borderRadius(70)
          .border({ width: 1.5, color: this.view.vm.scanning ? this.themeRingInner() : this.themeRingIdleInner() })
        Row()
          .width(96)
          .height(96)
          .borderRadius(48)
          .backgroundColor(this.view.vm.scanning ? this.themeColorSoft() : this.themeCore())
        // 扫描态雷达波纹：两层同心圆交替向外扩散并淡出
        if (this.view.vm.scanning) {
          Row()
            .width(96)
            .height(96)
            .borderRadius(48)
            .border({ width: 2, color: this.themeColor })
            .scale({ x: this.waveOn ? 2.2 : 0.7, y: this.waveOn ? 2.2 : 0.7 })
            .opacity(this.waveOn ? 0.0 : 0.45)
          Row()
            .width(96)
            .height(96)
            .borderRadius(48)
            .border({ width: 2, color: this.themeColor })
            .scale({ x: this.waveOn ? 0.7 : 2.2, y: this.waveOn ? 0.7 : 2.2 })
            .opacity(this.waveOn ? 0.45 : 0.0)
        }
        Path({ width: 24, height: 24, commands: ICON_DEVICE })
          .fill(Color.Transparent)
          .stroke(this.themeColor)
          .strokeWidth(2.2)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .scale({ x: 1.7, y: 1.7 })
      }
      .width(200)
      .height(200)
      .margin({ top: 8, bottom: 12 })

      Text(this.view.vm.scanning ? '正在搜索附近的体重秤' : '请唤醒体重秤并点击扫描')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_PRIMARY_TEXT)
      Text(this.view.vm.scanning ? '请站上秤或轻踩唤醒，保持设备靠近手机' :
        '支持多种品牌体脂秤，唤醒后点击下方按钮开始匹配')
        .fontSize(13)
        .fontColor(COLOR_SECONDARY_TEXT)
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })
        .padding({ left: 24, right: 24 })

      // 轻量气泡提示：引导新用户点击下方「开始扫描」；关闭热区 ≥44×44
      if (this.scanTipVisible && !this.view.vm.scanning) {
        Row() {
          Column() {
            Text('如何开始？')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_PRIMARY_TEXT)
            Text('点击下方「开始扫描」，发现附近的体重秤')
              .fontSize(12)
              .fontColor(COLOR_SECONDARY_TEXT)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          // 关闭按钮：44×44 透明热区，保证可点击性
          Text('×')
            .fontSize(18)
            .fontColor(COLOR_TERTIARY_TEXT)
            .width(44)
            .height(44)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.scanTipVisible = false;
            })
        }
        .width('100%')
        .padding({ left: 12, top: 12, bottom: 12, right: 4 })
        .margin({ top: 20 })
        .backgroundColor('#F7F8FA')
        .borderRadius(14)
        .border({ width: 1, color: COLOR_DIVIDER })
      }

      // 核心操作：中部主按钮承担「开始 / 停止」，圆角收敛为 16vp，默认涟漪反馈
      if (!this.view.vm.scanning) {
        Button('开始扫描', { type: ButtonType.Normal, stateEffect: true })
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor(this.themeColor)
          .height(44)
          .width(200)
          .borderRadius(16)
          .margin({ top: 16 })
          .onClick(() => {
            if (this.view.vm.bluetoothState === 'off') {
              this.toast('请先在系统设置中打开蓝牙');
              return;
            }
            this.scanTipVisible = false;
            this.view.vm.startScan();
            this.startWaveLoop();
          })
      } else {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(Color.White)
            Text('停止扫描')
              .fontSize(15)
              .fontColor(Color.White)
          }
        }
        .height(44)
        .width(200)
        .borderRadius(16)
        .backgroundColor(this.themeColor)
        .margin({ top: 16 })
        .onClick(() => {
          this.view.vm.stopScan();
          this.stopWaveLoop();
        })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 扫描结果卡片：名称 / MAC / RSSI 信号格 / 协议标签 / 连接绑定 */
  @Builder
  DeviceCard(item: DeviceItem) {
    Column() {
      Row() {
        Row() {
          Path({ width: 24, height: 24, commands: ICON_DEVICE })
            .fill(Color.Transparent)
            .stroke(item.isScale ? this.themeColor : COLOR_TERTIARY_TEXT)
            .strokeWidth(2)
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(item.isScale ? this.themeColorSoft() : COLOR_TAG_MUTED)
        .justifyContent(FlexAlign.Center)

        Column() {
          Text(item.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PRIMARY_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`MAC ${item.deviceId}`)
            .fontSize(11)
            .fontColor(COLOR_TERTIARY_TEXT)
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })

        Column() {
          this.SignalBars(item.rssi)
          Text(`${item.rssi} dBm`)
            .fontSize(11)
            .fontColor(COLOR_TERTIARY_TEXT)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')

      Row() {
        Text(item.shortName)
          .fontSize(12)
          .fontColor(item.isScale ? this.themeColor : COLOR_TERTIARY_TEXT)
          .backgroundColor(item.isScale ? this.themeColorSoft() : COLOR_TAG_MUTED)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
          .margin({ right: 8 })
        Text(item.isScale ? '已适配' : '未识别')
          .fontSize(12)
          .fontColor(COLOR_TERTIARY_TEXT)
          .layoutWeight(1)
        if (item.isScale) {
          Button(this.view.vm.lastDeviceId === item.deviceId ? '重新绑定' : '连接 / 绑定')
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor(this.themeColor)
            .height(40)
            .padding({ left: 14, right: 14 })
            .borderRadius(20)
            .onClick(() => {
              this.view.vm.connectDevice(item);
            })
        }
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
  }

  /** RSSI 信号格：≥-55 满格，≥-68 三格，≥-80 两格，其余一格 */
  @Builder
  SignalBars(rssi: number) {
    Row({ space: 2 }) {
      ForEach([1, 2, 3, 4], (i: number) => {
        Row()
          .width(3)
          .height(3 + i * 3)
          .borderRadius(1.5)
          .backgroundColor(i <= this.signalLevel(rssi) ? this.themeColor : COLOR_BAR_OFF)
      }, (i: number) => `${i}`)
    }
    .height(16)
    .alignItems(VerticalAlign.Bottom)
  }

  /** 辅助信息卡：两列品牌标签，默认预览 4 个，可展开全部 */
  @Builder
  BrandCard() {
    Column({ space: 12 }) {
      Row() {
        Text('支持的设备品牌')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PRIMARY_TEXT)
          .layoutWeight(1)
        Text(`共 ${this.view.vm.listAdapters().length} 类`)
          .fontSize(12)
          .fontColor(COLOR_TERTIARY_TEXT)
      }
      .width('100%')

      Column({ space: 8 }) {
        ForEach(this.visibleBrandRows(), (pair: string[]) => {
          Row({ space: 8 }) {
            this.BrandTag(pair[0])
            if (pair.length > 1) {
              this.BrandTag(pair[1])
            }
          }
          .width('100%')
        }, (pair: string[]) => pair.join('|'))
      }
      .width('100%')

      Row() {
        Text(this.brandsExpanded ? '收起' : '查看更多')
          .fontSize(13)
          .fontColor(this.themeColor)
        Text(this.brandsExpanded ? '⌃' : '⌄')
          .fontSize(14)
          .fontColor(this.themeColor)
          .margin({ left: 4 })
      }
      .width('100%')
      .height(40)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.brandsExpanded = !this.brandsExpanded;
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
    .margin({ top: 12 })
  }

  @Builder
  BrandTag(name: string) {
    Text(name)
      .fontSize(12)
      .fontColor(COLOR_SECONDARY_TEXT)
      .backgroundColor(this.themeColorSoft())
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .borderRadius(12)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .layoutWeight(1)
  }

  // ---------- 设备页派生数据 ----------
  private bluetoothStateText(): string {
    switch (this.view.vm.bluetoothState) {
      case 'on':
        return '蓝牙已开启';
      case 'off':
        return '蓝牙未开启';
      case 'switching':
        return '蓝牙切换中';
      default:
        return '蓝牙状态未知';
    }
  }

  private bluetoothStateColor(): string {
    const state: string = this.view.vm.bluetoothState;
    if (state === 'on') {
      return this.themeColor;
    }
    if (state === 'off') {
      return COLOR_WARN;
    }
    return COLOR_TERTIARY_TEXT;
  }

  private deviceSubtitle(): string {
    if (this.view.vm.devices.length > 0) {
      return `已发现 ${this.view.vm.devices.length} 台设备，选择一台连接后即可称重`;
    }
    if (this.view.vm.scanning) {
      return '正在搜索 · 点击下方「停止扫描」可结束';
    }
    if (this.view.vm.bluetoothState === 'off') {
      return '蓝牙未开启，请先在系统设置中打开蓝牙';
    }
    return '支持多种品牌体脂秤，点击扫描开始匹配';
  }

  private signalLevel(rssi: number): number {
    if (rssi >= -55) {
      return 4;
    }
    if (rssi >= -68) {
      return 3;
    }
    if (rssi >= -80) {
      return 2;
    }
    return 1;
  }

  /** 品牌短名两两成行，供两列网格渲染 */
  private visibleBrandRows(): string[][] {
    const all: AdapterInfo[] = this.view.vm.listAdapters();
    const shown: AdapterInfo[] = this.brandsExpanded ? all : all.slice(0, BRAND_PREVIEW_COUNT);
    const rows: string[][] = [];
    for (let i = 0; i < shown.length; i += 2) {
      const row: string[] = [shown[i].shortName];
      if (i + 1 < shown.length) {
        row.push(shown[i + 1].shortName);
      }
      rows.push(row);
    }
    return rows;
  }

  // ==================== 我的模块 ====================
  @Builder
  MineTab() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.croppingAvatar) {
          this.AvatarCropPage()
        } else if (this.detailPage !== 'none') {
          this.DetailPage(this.detailPage)
        } else if (this.editingProfile) {
          this.ProfileEditor()
        } else {
          this.MineHeader()
          this.MineSummary()
          this.MineStats()
          this.ThemeColorSection()
          this.MineActions()
          this.AboutCard()
          Text('数据仅保存在本机，不联网、不上传。BMI 与身体成分为估算值，不能替代医疗诊断。')
            .fontSize(12)
            .fontColor(COLOR_TERTIARY_TEXT)
            .width('100%')
        }
      }
      .width('100%')
      .padding({
        left: SCREEN_PADDING,
        right: SCREEN_PADDING,
        top: SCREEN_PADDING,
        bottom: SCROLL_BOTTOM_PADDING
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  /**
   * 个人信息卡片（一级）：仅展示头像与昵称。
   * - 头像可点击：直接进入自定义头像（相册选图 + 裁剪），头像本身不显示任何编辑角标 / 字样。
   * - 昵称区域可点击：进入二级编辑页编辑昵称与其余字段。
   * 两者为并列点击目标，卡片容器本身不设 onClick，避免事件冒泡冲突。
   */
  @Builder
  MineHeader() {
    Column() {
      Text('个人信息')
        .fontSize(14)
        .fontColor(COLOR_TERTIARY_TEXT)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 12 })
      Row() {
        // 头像：点击直接自定义；用 Stack 包裹以便挂载 onClick（自定义 @Builder 不能直接链式 .onClick）
        Stack() {
          this.AvatarCircle()
        }
        .width(64)
        .height(64)
        .onClick(() => {
          this.pickAvatar();
        })

        // 昵称区域：点击进入编辑页
        Column() {
          Text(this.view.vm.profile.nickname.length > 0 ? this.view.vm.profile.nickname : '我的健康档案')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_PRIMARY_TEXT)
          Text('点击编辑资料')
            .fontSize(12)
            .fontColor(COLOR_TERTIARY_TEXT)
            .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 16 })
        .onClick(() => {
          this.syncFormFromProfile();
          this.saveHint = '';
          this.editingProfile = true;
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  /** 圆形头像：有自定义头像则显示图片（裁剪为圆形），否则主题色占位人形 */
  @Builder
  AvatarCircle() {
    if (this.view.vm.profile.avatarUri.length > 0) {
      Image(this.view.vm.profile.avatarUri)
        .width(64)
        .height(64)
        .borderRadius(32)
        .clip(true)
        .objectFit(ImageFit.Cover)
    } else {
      Stack() {
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(36)
          .fontColor([this.themeColor])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      }
      .width(64)
      .height(64)
      .borderRadius(32)
      .backgroundColor(this.themeColorSoft())
    }
  }

  /** 从相册选择一张照片作为头像，进入自定义裁剪页后再持久化 */
  private async pickAvatar(): Promise<void> {
    const context = AppStorage.get<common.UIAbilityContext>('app_ability_context');
    if (!context) {
      this.toast('应用上下文未就绪，请重启应用');
      return;
    }
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result = await picker.select(options);
      if (!result.photoUris || result.photoUris.length === 0) {
        return;
      }
      const src: string = result.photoUris[0];
      const srcImage = image.createImageSource(src);
      const pm: image.PixelMap = await srcImage.createPixelMap();
      const info = await pm.getImageInfo();
      this.cropSrcW = info.size.width;
      this.cropSrcH = info.size.height;
      // 源图按 cover 适配到正方形画布并居中
      this.cropScale = Math.max(this.CROP_CANVAS / this.cropSrcW, this.CROP_CANVAS / this.cropSrcH);
      this.cropOffX = (this.CROP_CANVAS - this.cropSrcW * this.cropScale) / 2;
      this.cropOffY = (this.CROP_CANVAS - this.cropSrcH * this.cropScale) / 2;
      // 初始裁剪框：居中、边长 70% 画布
      this.cropBoxSize = Math.round(this.CROP_CANVAS * 0.7);
      this.cropBoxX = (this.CROP_CANVAS - this.cropBoxSize) / 2;
      this.cropBoxY = (this.CROP_CANVAS - this.cropBoxSize) / 2;
      this.cropPixelMap = pm;
      this.croppingAvatar = true;
    } catch (err) {
      // 用户取消选择会以异常退出，忽略；仅记录
      hilog.error(0x0000, 'AvatarPicker', 'pickAvatar failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 自定义裁剪页：拖动裁剪框调整位置，滑块调整裁剪尺寸，确认后裁出圆形头像 */
  @Builder
  AvatarCropPage() {
    Column() {
      Row() {
        Button('取消', { type: ButtonType.Capsule })
          .fontSize(14)
          .fontColor(this.themeColor)
          .backgroundColor(this.themeColorSoft())
          .height(40)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.cancelCrop();
          })
        Text('调整头像')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PRIMARY_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Button('使用', { type: ButtonType.Capsule })
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(this.themeColor)
          .height(40)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.cropAndSave();
          })
      }
      .width('100%')

      // 裁剪画布：固定正方形，源图 cover 居中，裁剪框在其上
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.cropPixelMap) {
          Image(this.cropPixelMap)
            .width(this.cropSrcW * this.cropScale)
            .height(this.cropSrcH * this.cropScale)
            .position({ x: this.cropOffX, y: this.cropOffY })
            .objectFit(ImageFit.Fill)
        }
        // 裁剪框外的暗角遮罩（四块），强化聚焦
        Row().width('100%').height(this.cropBoxY).backgroundColor('#80000000')
          .position({ x: 0, y: 0 })
        Row().width(this.cropBoxX).height(this.cropBoxSize).backgroundColor('#80000000')
          .position({ x: 0, y: this.cropBoxY })
        Row().width(this.CROP_CANVAS - this.cropBoxX - this.cropBoxSize).height(this.cropBoxSize)
          .backgroundColor('#80000000').position({ x: this.cropBoxX + this.cropBoxSize, y: this.cropBoxY })
        Row().width('100%').height(this.CROP_CANVAS - this.cropBoxY - this.cropBoxSize)
          .backgroundColor('#80000000').position({ x: 0, y: this.cropBoxY + this.cropBoxSize })
        // 裁剪框：可拖动，白色描边 + 主题色角标
        Stack() {
          Row()
            .width('100%')
            .height('100%')
            .border({ width: 2, color: Color.White })
            .borderRadius(4)
        }
        .width(this.cropBoxSize)
        .height(this.cropBoxSize)
        .position({ x: this.cropBoxX, y: this.cropBoxY })
        .gesture(
          PanGesture()
            .onActionStart(() => {
              this.panStartX = this.cropBoxX;
              this.panStartY = this.cropBoxY;
            })
            .onActionUpdate((e: PanGestureEvent) => {
              const nx: number = Math.min(Math.max(this.panStartX + e.offsetX, 0),
                this.CROP_CANVAS - this.cropBoxSize);
              const ny: number = Math.min(Math.max(this.panStartY + e.offsetY, 0),
                this.CROP_CANVAS - this.cropBoxSize);
              this.cropBoxX = nx;
              this.cropBoxY = ny;
            })
        )
      }
      .width(this.CROP_CANVAS)
      .height(this.CROP_CANVAS)
      .backgroundColor('#1A1A1A')
      .margin({ top: 24 })
      .clip(true)

      Text('拖动选框调整位置，下方滑块调整裁剪尺寸')
        .fontSize(12)
        .fontColor(COLOR_TERTIARY_TEXT)
        .margin({ top: 16 })

      Slider({
        value: this.cropBoxSize,
        min: 80,
        max: this.CROP_CANVAS - 20,
        step: 2,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .selectedColor(this.themeColor)
        .margin({ top: 8 })
        .onChange((value: number) => {
          // 缩放时保持中心不动
          const cx: number = this.cropBoxX + this.cropBoxSize / 2;
          const cy: number = this.cropBoxY + this.cropBoxSize / 2;
          const size: number = Math.round(value);
          let x: number = cx - size / 2;
          let y: number = cy - size / 2;
          x = Math.min(Math.max(x, 0), this.CROP_CANVAS - size);
          y = Math.min(Math.max(y, 0), this.CROP_CANVAS - size);
          this.cropBoxSize = size;
          this.cropBoxX = x;
          this.cropBoxY = y;
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: SCREEN_PADDING, right: SCREEN_PADDING, top: SCREEN_PADDING })
    .backgroundColor(COLOR_BG)
    .alignItems(HorizontalAlign.Center)
  }

  /** 取消裁剪：释放 PixelMap，回到我的页 */
  private cancelCrop(): void {
    this.releaseCropPixelMap();
    this.croppingAvatar = false;
  }

  /** 裁剪并保存：把画布坐标系的裁剪框换算到源像素，crop → 打包 jpg → 写入沙箱 → 持久化 */
  private async cropAndSave(): Promise<void> {
    if (!this.cropPixelMap) {
      this.croppingAvatar = false;
      return;
    }
    const context = AppStorage.get<common.UIAbilityContext>('app_ability_context');
    if (!context) {
      this.toast('应用上下文未就绪，请重启应用');
      return;
    }
    try {
      const pm: image.PixelMap = this.cropPixelMap;
      // 画布坐标 → 源像素坐标
      let srcX: number = (this.cropBoxX - this.cropOffX) / this.cropScale;
      let srcY: number = (this.cropBoxY - this.cropOffY) / this.cropScale;
      let srcSize: number = this.cropBoxSize / this.cropScale;
      // 夹取在源图范围内
      srcX = Math.min(Math.max(srcX, 0), this.cropSrcW - 1);
      srcY = Math.min(Math.max(srcY, 0), this.cropSrcH - 1);
      srcSize = Math.min(srcSize, this.cropSrcW - srcX, this.cropSrcH - srcY);
      const region: image.Region = {
        size: { width: Math.round(srcSize), height: Math.round(srcSize) },
        x: Math.round(srcX),
        y: Math.round(srcY)
      };
      await pm.crop(region);
      const packer = image.createImagePacker();
      const buf: ArrayBuffer = await packer.packToData(pm, { format: 'image/jpeg', quality: 90 });
      const destPath: string = `${context.filesDir}/avatar_${Date.now()}.jpg`;
      const fd: fileIo.File = fileIo.openSync(destPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(fd.fd, buf);
      fileIo.closeSync(fd.fd);
      const avatarUri: string = fileUri.getUriFromPath(destPath);
      const ok = await this.view.vm.setAvatar(avatarUri);
      if (!ok) {
        this.toast('头像已裁剪，但本地保存失败');
      } else {
        this.toast('头像已更新');
      }
    } catch (err) {
      hilog.error(0x0000, 'AvatarCrop', 'cropAndSave failed: %{public}s', JSON.stringify(err));
      this.toast('裁剪失败，请重试');
    } finally {
      this.releaseCropPixelMap();
      this.croppingAvatar = false;
    }
  }

  /** 释放裁剪用的临时 PixelMap，避免内存泄漏 */
  private releaseCropPixelMap(): void {
    if (this.cropPixelMap) {
      try {
        this.cropPixelMap.release();
      } catch (e) {
        // 释放失败不影响业务流程
      }
      this.cropPixelMap = null;
    }
  }

  @Builder
  MineSummary() {
    Column() {
      Text('档案信息')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_PRIMARY_TEXT)
        .width('100%')
        .margin({ bottom: 12 })
      this.SummaryRow('目标体重', `${this.view.vm.profile.targetWeightKg.toFixed(1)} kg`)
      this.SummaryRow('体重单位', this.view.vm.displayUnitSymbol())
      this.SummaryRow('BMI 标准', this.formBmiStandardIndex === 1 ? 'WHO 标准' : '中国标准')
      this.SummaryRow('身高', `${this.view.vm.profile.heightCm} cm`)
      this.SummaryRow('保存位置', '仅本机')
    }
    .width('100%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SummaryRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontColor(COLOR_SECONDARY_TEXT)
        .layoutWeight(1)
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_PRIMARY_TEXT)
    }
    .width('100%')
    .height(40)
  }

  @Builder
  MineStats() {
    Column() {
      Text('数据概览')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_PRIMARY_TEXT)
        .width('100%')
        .margin({ bottom: 12 })
      GridRow({ columns: 2, gutter: { x: 12, y: 12 } }) {
        GridCol() {
          this.MetricTile('累计称重', `${this.view.vm.recordCount()} 次`)
        }
        GridCol() {
          this.MetricTile('最近体重', this.view.vm.latestWeightKg() > 0 ?
            `${this.view.vm.latestWeightKg().toFixed(2)} kg` : '--')
        }
        GridCol() {
          this.MetricTile('当前 BMI', this.view.vm.latestWeightKg() > 0 ?
            this.view.vm.currentBmi().toFixed(1) : '--')
        }
        GridCol() {
          this.MetricTile('距目标', this.targetGapText())
        }
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MineActions() {
    Column() {
      Text('功能')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_PRIMARY_TEXT)
        .width('100%')
        .margin({ bottom: 4 })

      Row() {
        Text('导出 CSV 到剪贴板').fontSize(16).fontColor(COLOR_PRIMARY_TEXT).layoutWeight(1)
        Text('›').fontSize(20).fontColor(COLOR_TERTIARY_TEXT)
      }
      .width('100%')
      .height(BUTTON_HEIGHT)
      .border({ width: { bottom: 1 }, color: COLOR_DIVIDER })
      .onClick(() => {
        this.copyCsv();
      })

      Row() {
        Text('查看支持的设备品牌').fontSize(16).fontColor(COLOR_PRIMARY_TEXT).layoutWeight(1)
        Text('›').fontSize(20).fontColor(COLOR_TERTIARY_TEXT)
      }
      .width('100%')
      .height(BUTTON_HEIGHT)
      .border({ width: { bottom: 1 }, color: COLOR_DIVIDER })
      .onClick(() => {
        this.currentTab = 2;
      })

      Row() {
        Text('清空全部记录').fontSize(16).fontColor('#C4261D').layoutWeight(1)
        Text('›').fontSize(20).fontColor(COLOR_TERTIARY_TEXT)
      }
      .width('100%')
      .height(BUTTON_HEIGHT)
      .onClick(() => {
        this.view.vm.clearRecords();
        this.toast('记录已清空');
      })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  /** 「我的」页：关于 / 隐私 / 开源 入口卡片 */
  @Builder
  AboutCard() {
    Column() {
      Text('关于')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_PRIMARY_TEXT)
        .width('100%')
        .margin({ bottom: 4 })

      this.AboutRow('关于应用', 'about')
      this.AboutRow('隐私说明', 'privacy')
      this.AboutRow('开源声明', 'opensource')
    }
    .width('100%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AboutRow(label: string, kind: 'about' | 'privacy' | 'opensource') {
    Row() {
      Text(label).fontSize(16).fontColor(COLOR_PRIMARY_TEXT).layoutWeight(1)
      Text('›').fontSize(20).fontColor(COLOR_TERTIARY_TEXT)
    }
    .width('100%')
    .height(BUTTON_HEIGHT)
    .border({ width: { bottom: 1 }, color: COLOR_DIVIDER })
    .onClick(() => {
      this.detailPage = kind;
    })
  }

  /** 详情子页：关于应用 / 隐私说明 / 开源声明 */
  @Builder
  DetailPage(kind: string) {
    Column() {
      Row() {
        Button('返回', { type: ButtonType.Capsule })
          .fontSize(14)
          .fontColor(this.themeColor)
          .backgroundColor(this.themeColorSoft())
          .height(40)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.detailPage = 'none';
          })
        Text(this.detailTitle(kind))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PRIMARY_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
      }
      .width('100%')

      if (kind === 'about') {
        Row() {
          this.AppLogo(72)
        }
        .margin({ top: 4, bottom: 4 })
      }

      Scroll() {
        Column({ space: 12 }) {
          ForEach(this.detailParagraphs(kind), (p: string) => {
            Text(p)
              .fontSize(15)
              .fontColor(COLOR_SECONDARY_TEXT)
              .lineHeight(24)
              .width('100%')
          }, (p: string) => p)
        }
        .width('100%')
        .padding(20)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: SCREEN_PADDING, right: SCREEN_PADDING, top: SCREEN_PADDING })
    .backgroundColor(COLOR_BG)
    .alignItems(HorizontalAlign.Center)
  }

  private detailTitle(kind: string): string {
    if (kind === 'privacy') {
      return '隐私说明';
    }
    if (kind === 'opensource') {
      return '开源声明';
    }
    return '关于应用';
  }

  private detailParagraphs(kind: string): Array<string> {
    if (kind === 'privacy') {
      return [
        '本应用所有健康数据（体重、身高、年龄、头像）仅保存在设备本地（应用沙箱 preferences 与 files 目录），不上传任何服务器，不联网。',
        '蓝牙权限仅用于发现并连接您主动选择的体脂秤、读取秤上数据；应用不会在后台持续扫描。',
        '头像图片仅存储在本地沙箱，不会被分享或上传。',
        '您可随时在「我的 → 清空全部记录」删除历史数据，或在系统设置中卸载应用以彻底清除。',
        '本应用不收集、不分析、不向第三方提供任何个人信息。'
      ];
    }
    if (kind === 'opensource') {
      return [
        '本应用的蓝牙秤协议适配灵感来自开源项目 scales-bridge（xiangbohua）与 openScale，后者提供了大量厂商体重秤的通信协议参考。',
        '协议解析层（Standard / Mi / Yunmai / QN / VScale / Broadcast / ScalesBridge 适配器）为本项目基于 HarmonyOS ArkTS 重新实现，并非直接复用上述项目的代码。',
        '本项目以学习与原型验证为目的构建；如用于正式发布，请遵守相关开源协议，并自行完成真机适配与合规审查。',
        '数据计算（BMI、体脂率、肌肉量、水分）均为基于公开公式的估算，仅供参考，不能替代专业医疗建议。'
      ];
    }
    return [
      '轻秤 · 鸿蒙体重 是一款运行在 HarmonyOS 上的轻量体重与身体成分管理应用，支持通过蓝牙连接市面上常见的体脂秤，自动读取体重并估算 BMI、体脂率、肌肉量等指标。',
      '主要功能：蓝牙扫描与连接、手动录入（支持两位小数）、BMI 计算（中国 & WHO 标准）、历史趋势图表、数据本机保存、中国式传统色主题。',
      '主题说明：应用内强调色可在「我的 → 主题配色」切换并持久化；桌面启动图标为静态资源，需重新生成打包才会变化。',
      '版本：1.0.0'
    ];
  }

  /** 「我的」页：中国传统色主题选择。点击色块即时换色并持久化 */
  @Builder
  ThemeColorSection() {
    Column() {
      Text('主题配色')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_PRIMARY_TEXT)
        .width('100%')
        .margin({ bottom: 4 })
      Text('选用中国传统色，应用内的按钮、胶囊与图表会同步换色')
        .fontSize(12)
        .fontColor(COLOR_TERTIARY_TEXT)
        .width('100%')
        .margin({ bottom: 12 })
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignContent: FlexAlign.Start }) {
        ForEach(THEME_COLORS, (c: ThemeColor, idx: number) => {
          Column() {
            Stack() {
              Row()
                .width(40)
                .height(40)
                .borderRadius(20)
                .backgroundColor(c.hex)
              if (this.themeColor === c.hex) {
                Path({ width: 16, height: 16, commands: 'M3 8 L7 12 L13 4' })
                  .stroke(Color.White)
                  .strokeWidth(2)
                  .strokeLineCap(LineCapStyle.Round)
                  .strokeLineJoin(LineJoinStyle.Round)
              }
            }
            .width(48)
            .height(48)
            .alignContent(Alignment.Center)
            Text(c.name)
              .fontSize(11)
              .fontColor(this.themeColor === c.hex ? this.themeColor : COLOR_TERTIARY_TEXT)
              .margin({ top: 4 })
          }
          .width(56)
          .alignItems(HorizontalAlign.Center)
          .margin({ right: 4, bottom: 8 })
          .onClick(() => {
            this.themeColor = c.hex;
            this.view.vm.setThemeColor(idx);
          })
        }, (c: ThemeColor) => c.hex)
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  // ==================== 档案编辑（页内子页） ====================
  @Builder
  ProfileEditor() {
    Column({ space: 16 }) {
      Row() {
        Button('返回', { type: ButtonType.Capsule })
          .fontSize(14)
          .fontColor(this.themeColor)
          .backgroundColor('#E8F0FF')
          .height(40)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.editingProfile = false;
          })
        Text('编辑个人档案')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_PRIMARY_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
      }
      .width('100%')

      // 个人信息：头像（与一级一致：干净呈现、点击直接自定义）+ 昵称
      Column({ space: 12 }) {
        Text('个人信息')
          .fontSize(14)
          .fontColor(COLOR_TERTIARY_TEXT)
          .fontWeight(FontWeight.Medium)
          .width('100%')
        Row() {
          // 头像：与一级保持一致，不显示编辑角标 / 字样，点击直接自定义
          Stack() {
            this.AvatarCircle()
          }
          .width(64)
          .height(64)
          .onClick(() => {
            this.pickAvatar();
          })

          Column() {
            Text('昵称')
              .fontSize(16)
              .fontColor(COLOR_PRIMARY_TEXT)
              .width('100%')
            TextInput({ placeholder: '给自己起个名字（可留空）', text: this.formNickname })
              .type(InputType.Normal)
              .fontSize(16)
              .height(BUTTON_HEIGHT)
              .width('100%')
              .backgroundColor('#F7F8FA')
              .onChange((v: string) => {
                this.formNickname = v;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 16 })
        }
        .width('100%')
      }
      .width('100%')
      .padding(20)
      .backgroundColor(COLOR_CARD)
      .borderRadius(CARD_RADIUS)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 4 }) {
        Text('身高 (cm)')
          .fontSize(16)
          .fontColor(COLOR_PRIMARY_TEXT)
          .width('100%')
          .margin({ top: 12 })
        TextInput({ placeholder: '170', text: this.formHeight })
          .type(InputType.NUMBER_DECIMAL)
          .inputFilter('^\\d{0,3}(\\.\\d{0,1})?$')
          .fontSize(16)
          .height(BUTTON_HEIGHT)
          .width('100%')
          .backgroundColor('#F7F8FA')
          .onChange((v: string) => {
            this.formHeight = v;
          })

        Text('年龄')
          .fontSize(16)
          .fontColor(COLOR_PRIMARY_TEXT)
          .width('100%')
          .margin({ top: 12 })
        TextInput({ placeholder: '30', text: this.formAge })
          .type(InputType.Number)
          .fontSize(16)
          .height(BUTTON_HEIGHT)
          .width('100%')
          .backgroundColor('#F7F8FA')
          .onChange((v: string) => {
            this.formAge = v;
          })

        Text('目标体重 (kg)')
          .fontSize(16)
          .fontColor(COLOR_PRIMARY_TEXT)
          .width('100%')
          .margin({ top: 12 })
        TextInput({ placeholder: '65.0', text: this.formTarget })
          .type(InputType.NUMBER_DECIMAL)
          .inputFilter('^\\d{0,3}(\\.\\d{0,1})?$')
          .fontSize(16)
          .height(BUTTON_HEIGHT)
          .width('100%')
          .backgroundColor('#F7F8FA')
          .onChange((v: string) => {
            this.formTarget = v;
          })

        // 以下三个下拉直接读写本组件的 @State，不使用 @Builder 按值传参
        Row() {
          Text('性别').fontSize(16).fontColor(COLOR_PRIMARY_TEXT).layoutWeight(1)
          Select([{ value: '男' }, { value: '女' }])
            .selected(this.formGenderIndex)
            .value(this.formGenderIndex === 1 ? '女' : '男')
            .onSelect((index: number) => {
              this.formGenderIndex = index;
            })
        }
        .width('100%')
        .height(BUTTON_HEIGHT)
        .margin({ top: 12 })

        Row() {
          Text('体重单位').fontSize(16).fontColor(COLOR_PRIMARY_TEXT).layoutWeight(1)
          Select([{ value: 'kg' }, { value: 'lb' }, { value: 'st' }])
            .selected(this.formUnitIndex)
            .value(this.formUnitIndex === 1 ? 'lb' : (this.formUnitIndex === 2 ? 'st' : 'kg'))
            .onSelect((index: number) => {
              this.formUnitIndex = index;
            })
        }
        .width('100%')
        .height(BUTTON_HEIGHT)

        Row() {
          Text('BMI 标准').fontSize(16).fontColor(COLOR_PRIMARY_TEXT).layoutWeight(1)
          Select([{ value: '中国标准' }, { value: 'WHO 标准' }])
            .selected(this.formBmiStandardIndex)
            .value(this.formBmiStandardIndex === 0 ? '中国标准' : 'WHO 标准')
            .onSelect((index: number) => {
              this.formBmiStandardIndex = index;
            })
        }
        .width('100%')
        .height(BUTTON_HEIGHT)

        Text(this.view.vm.bmiStandardText())
          .fontSize(12)
          .fontColor(COLOR_TERTIARY_TEXT)
          .width('100%')
          .margin({ top: 4 })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(COLOR_CARD)
      .borderRadius(CARD_RADIUS)

      if (this.saveHint.length > 0) {
        Text(this.saveHint)
          .fontSize(14)
          .fontColor(this.saveOk ? '#11823B' : '#C4261D')
          .width('100%')
          .padding(12)
          .backgroundColor(this.saveOk ? '#EAF7EE' : '#FDECEA')
          .borderRadius(8)
      }

      Button('保存档案', { type: ButtonType.Capsule })
        .fontSize(16)
        .fontColor(Color.White)
        .backgroundColor(this.themeColor)
        .height(BUTTON_HEIGHT)
        .width('100%')
        .onClick(() => {
          this.saveProfile();
        })

      Text('保存后会立即重算全部历史记录的 BMI，并同步到首页与趋势页。')
        .fontSize(12)
        .fontColor(COLOR_TERTIARY_TEXT)
        .width('100%')
    }
    .width('100%')
  }

  // ==================== 交互逻辑 ====================
  /** 统一提示入口：使用未废弃的 UIContext.getPromptAction() */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // 提示仅作反馈，失败不阻断业务流程
    }
  }

  /** 启动扫描波纹：定时器每 1.5s 翻转 waveOn，驱动两层同心圆交替向外扩散；
   *  定时器自监测 view.vm.scanning，扫描结束自动停止，避免遗留动画。 */
  private startWaveLoop(): void {
    if (this.waveTimer !== 0) {
      return;
    }
    this.waveTimer = setInterval(() => {
      if (!this.view.vm.scanning) {
        this.stopWaveLoop();
        return;
      }
      // 全局 animateTo 已废弃，改用 UIContext 实例方法，避免编译告警
      this.getUIContext().animateTo({ duration: 1500, curve: Curve.EaseOut }, () => {
        this.waveOn = !this.waveOn;
      });
    }, 1500);
  }

  /** 停止扫描波纹：清除定时器并把波纹复位到静止态 */
  private stopWaveLoop(): void {
    if (this.waveTimer !== 0) {
      clearInterval(this.waveTimer);
      this.waveTimer = 0;
    }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.waveOn = false;
    });
  }

  /** 手动录入：支持两位小数，按当前展示单位换算为 kg */
  private submitManualWeight(): void {
    const value = parseFloat(this.manualWeightInput);
    if (!isFinite(value) || value <= 0 || value > 500) {
      this.toast('请输入 0 ~ 500 之间的有效体重');
      return;
    }
    const kg = Math.round(convertToKg(value, this.view.vm.profile.displayUnit) * 100) / 100;
    if (!isFinite(kg) || kg <= 0 || kg > 500) {
      this.toast('换算后的体重超出有效范围');
      return;
    }
    this.view.vm.addManualWeight(kg);
    // 回填两位小数，让精度在输入框中直接可见
    this.manualWeightInput = value.toFixed(2);
    this.toast(`已记录 ${kg.toFixed(2)} kg`);
  }

  /** 保存档案：校验 → 等待持久化 → 回读 → 明确反馈 → 整页刷新 */
  private async saveProfile(): Promise<void> {
    const height = parseFloat(this.formHeight);
    const age = parseInt(this.formAge, 10);
    const target = parseFloat(this.formTarget);
    if (!isFinite(height) || height < 50 || height > 250) {
      this.toast('身高需在 50 ~ 250 cm 之间');
      return;
    }
    if (!isFinite(age) || age < 1 || age > 120) {
      this.toast('年龄需在 1 ~ 120 之间');
      return;
    }
    if (!isFinite(target) || target < 20 || target > 300) {
      this.toast('目标体重需在 20 ~ 300 kg 之间');
      return;
    }

    const gender = this.formGenderIndex === 1 ? Gender.FEMALE : Gender.MALE;
    const unit = this.formUnitIndex === 1 ? WeightUnit.LB :
      (this.formUnitIndex === 2 ? WeightUnit.ST : WeightUnit.KG);
    const standard = this.formBmiStandardIndex === 1 ?
      BmiStandardChoice.WHO : BmiStandardChoice.CHINA;
    const profile: UserProfile = {
      heightCm: Math.round(height),
      age: age,
      gender: gender,
      targetWeightKg: Math.round(target * 10) / 10,
      displayUnit: unit,
      bmiStandard: standard,
      nickname: this.formNickname.trim(),
      avatarUri: this.view.vm.profile.avatarUri
    };

    const saved = await this.view.vm.updateProfile(profile);
    this.syncFormFromProfile();
    if (saved) {
      this.saveOk = true;
      this.saveHint = `已保存：身高 ${profile.heightCm} cm · 目标 ${profile.targetWeightKg.toFixed(1)} kg · ` +
        `${this.formUnitIndex === 1 ? 'lb' : (this.formUnitIndex === 2 ? 'st' : 'kg')} · ` +
        `${this.formBmiStandardIndex === 1 ? 'WHO 标准' : '中国标准'}`;
      this.editingProfile = false;
      this.toast('档案已保存，历史 BMI 已重算');
    } else {
      // 内存状态已更新，但落盘失败：保留编辑页并明确告知，不再「毫无反应」
      this.saveOk = false;
      this.saveHint = '保存失败：本地存储未就绪，请重启应用后重试';
      this.toast('保存失败：本地存储未就绪');
    }
  }

  private copyCsv(): void {
    try {
      const csv = this.view.vm.exportCsv();
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, csv);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      systemPasteboard.setData(data).then(() => {
        this.toast(`已复制 ${this.view.vm.records.length} 条记录`);
      });
    } catch (err) {
      this.toast('导出失败，请稍后重试');
    }
  }

  private targetGapText(): string {
    const gap = this.view.vm.distanceToTargetKg();
    if (gap === null) {
      return '--';
    }
    if (Math.abs(gap) < 0.05) {
      return '已达成';
    }
    return gap > 0 ? `还需 ${gap.toFixed(1)} kg` : `低于目标 ${Math.abs(gap).toFixed(1)} kg`;
  }

  private bodyFatText(): string {
    const c = this.view.vm.bodyComposition();
    return c ? `${c.bodyFatPercent.toFixed(1)} %` : '--';
  }

  private muscleText(): string {
    const c = this.view.vm.bodyComposition();
    return c ? `${c.skeletalMuscleKg.toFixed(1)} kg` : '--';
  }

  private leanMassText(): string {
    const c = this.view.vm.bodyComposition();
    return c ? `${c.leanBodyMassKg.toFixed(1)} kg` : '--';
  }

  private waterText(): string {
    const c = this.view.vm.bodyComposition();
    return c ? `${c.bodyWaterPercent.toFixed(1)} %` : '--';
  }

  private deltaText(): string {
    const d = this.view.vm.weightDeltaKg();
    if (d === null) {
      return '';
    }
    if (Math.abs(d) < 0.05) {
      return '与上次持平';
    }
    return d > 0 ? `较上次 +${d.toFixed(2)} kg` : `较上次 ${d.toFixed(2)} kg`;
  }

  private formatDate(ts: number): string {
    const d = new Date(ts);
    return `${d.getFullYear()}-${this.pad2(d.getMonth() + 1)}-${this.pad2(d.getDate())} ` +
      `${this.pad2(d.getHours())}:${this.pad2(d.getMinutes())}`;
  }

  private formatShortDate(ts: number): string {
    const d = new Date(ts);
    return `${d.getMonth() + 1}/${d.getDate()}`;
  }

  private pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }
}
