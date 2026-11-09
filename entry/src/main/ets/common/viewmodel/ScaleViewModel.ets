/**
 * 应用主视图模型
 *
 * 职责：串联蓝牙连接 → 协议解析 → BMI 计算 → 本地存储 → UI 状态。
 * 所有 UI 状态用 @State / @Observed 驱动，避免界面层直接触碰蓝牙 API。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BmiStandardChoice, Gender, ScaleState, ScannedDevice, UserProfile, WeightReading,
  WeightRecord, WeightType, WeightUnit } from '../model/ScaleModels';
import { BmiClassification, BmiStandard, BodyComposition, calcBmi, classifyBmi,
  convertFromKg, estimateBodyComposition, idealWeightRangeKg, unitSymbol, weightAdvice } from '../util/BmiCalculator';
import { BtConnectionState, RawScanDevice, ScaleBluetoothService } from '../service/ScaleBluetoothService';
import { AdapterInfo, ProtocolRegistry } from '../service/ProtocolRegistry';
import { ProtocolAdapter } from '../service/ProtocolAdapter';
import { ScaleDataStore, defaultUserProfile } from '../service/ScaleDataStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'ScaleVM';

/** 设备展示项 */
export interface DeviceItem {
  deviceId: string;
  name: string;
  rssi: number;
  adapterId: string;
  adapterName: string;
  /** 品牌短名，用于设备卡片上的协议标签 */
  shortName: string;
  isScale: boolean;
}

/**
 * 应用状态
 */
export class ScaleViewModel {
  /** 用户档案 */
  profile: UserProfile = defaultUserProfile();
  /** 历史记录（倒序） */
  records: WeightRecord[] = [];
  /** 扫描到的设备 */
  devices: DeviceItem[] = [];
  /** 连接状态 */
  connectionState: BtConnectionState = BtConnectionState.IDLE;
  /** 状态提示文本 */
  statusText: string = '未连接，点击「扫描设备」开始';
  /** 实时体重（kg），未测量时为 -1 */
  liveWeightKg: number = -1;
  /** 最近一次稳定读数 */
  lastReading: WeightReading | null = null;
  /** 是否正在扫描 */
  scanning: boolean = false;
  /** 当前使用的协议名 */
  currentAdapterName: string = '';
  /** 已保存的上一台设备 */
  lastDeviceId: string = '';
  /** 系统蓝牙开关：'on' / 'off' / 'switching' / 'unknown' */
  bluetoothState: string = 'unknown';
  /** 主题色索引（对应「中国式传统颜色」色板），默认 0 = 黛绿 */
  themeColorIndex: number = 0;

  private bt: ScaleBluetoothService = new ScaleBluetoothService();
  private store: ScaleDataStore = new ScaleDataStore();
  private registry: ProtocolRegistry = new ProtocolRegistry();
  private recordSeq: number = 0;
  /** 状态变更回调（由 UI 注册，用于触发刷新） */
  private onChange: (() => void) | null = null;

  constructor() {
    this.bt.setCallbacks(
      (r: WeightReading) => { this.handleReading(r); },
      (s: BtConnectionState, msg?: string) => {
        this.connectionState = s;
        if (msg) {
          this.statusText = msg;
        }
        this.notifyChange();
      },
      (d: RawScanDevice) => { this.handleDeviceFound(d); }
    );
    // 注册广播型协议适配器
    const broadcast: ProtocolAdapter[] = [];
    const a = this.registry.create('broadcast-scale');
    if (a) {
      broadcast.push(a);
    }
    this.bt.setBroadcastAdapters(broadcast);
  }

  /** UI 注册刷新回调 */
  setOnChange(cb: () => void): void {
    this.onChange = cb;
  }

  /** 初始化：加载档案与历史 */
  async init(context: common.UIAbilityContext): Promise<void> {
    await this.store.init(context);
    this.profile = await this.store.loadProfile();
    this.records = await this.store.loadRecords();
    this.lastDeviceId = await this.store.loadLastDevice();
    this.themeColorIndex = await this.store.loadThemeColor();
    this.recordSeq = this.records.reduce((max: number, r: WeightRecord) => Math.max(max, r.id), 0);
    this.readBluetoothState();
    this.notifyChange();
  }

  /** 申请权限 */
  async requestPermissions(context: common.UIAbilityContext): Promise<boolean> {
    const ok = await this.bt.requestPermissions(context);
    if (!ok) {
      this.statusText = '缺少蓝牙或位置权限，无法扫描体重秤';
      this.notifyChange();
    }
    return ok;
  }

  /** 重新读取系统蓝牙开关并刷新界面（进入设备页时调用） */
  refreshBluetoothState(): void {
    this.readBluetoothState();
    this.notifyChange();
  }

  private readBluetoothState(): void {
    this.bluetoothState = this.bt.getBluetoothState();
  }

  /** 开始扫描 */
  startScan(): void {
    this.readBluetoothState();
    this.devices = [];
    this.scanning = true;
    this.statusText = '正在扫描附近的体重秤...';
    this.bt.startScan([]);
    this.notifyChange();
  }

  /** 停止扫描 */
  stopScan(): void {
    this.scanning = false;
    this.bt.stopScan();
    this.statusText = '扫描已停止';
    this.notifyChange();
  }

  /** 处理扫描到设备 */
  private handleDeviceFound(d: RawScanDevice): void {
    const adapterId = this.registry.identify(d.name, d.serviceUuids, d.manufacturerData, d.serviceData);
    const isScale = adapterId !== null;
    let adapterName = '未识别设备';
    let shortName = '未识别';
    if (adapterId) {
      const item = this.registry.list().find((x: AdapterInfo) => x.id === adapterId);
      if (item) {
        adapterName = item.displayName;
        shortName = item.shortName;
      }
    }
    // 更新或插入
    const idx = this.devices.findIndex((x: DeviceItem) => x.deviceId === d.deviceId);
    const entry: DeviceItem = {
      deviceId: d.deviceId,
      name: d.name || '未知设备',
      rssi: d.rssi,
      adapterId: adapterId ?? '',
      adapterName: adapterName,
      shortName: shortName,
      isScale: isScale
    };
    if (idx >= 0) {
      this.devices[idx] = entry;
    } else {
      this.devices.push(entry);
    }
    // 识别到的秤排前面，再按信号排序
    this.devices.sort((a: DeviceItem, b: DeviceItem) => {
      if (a.isScale !== b.isScale) {
        return a.isScale ? -1 : 1;
      }
      return b.rssi - a.rssi;
    });
    this.notifyChange();
  }

  /** 连接设备 */
  async connectDevice(item: DeviceItem): Promise<void> {
    this.stopScan();
    const adapterId = item.adapterId || 'standard';
    const adapter = this.registry.create(adapterId);
    if (!adapter) {
      this.statusText = '未找到对应的协议适配器';
      this.notifyChange();
      return;
    }
    this.currentAdapterName = adapter.displayName;
    this.statusText = `正在连接 ${item.name} ...`;
    this.notifyChange();

    const ok = await this.bt.connect(item.deviceId, adapter);
    if (ok) {
      await this.store.saveLastDevice(item.deviceId);
      this.lastDeviceId = item.deviceId;
    }
    this.notifyChange();
  }

  /** 断开连接 */
  disconnect(): void {
    this.bt.disconnect();
    this.connectionState = BtConnectionState.DISCONNECTED;
    this.statusText = '已断开连接';
    this.notifyChange();
  }

  /** 处理读数：实时显示 + 稳定后入库 */
  private handleReading(r: WeightReading): void {
    this.liveWeightKg = r.weightKg;
    this.lastReading = r;
    if (r.state === ScaleState.STABLE) {
      this.statusText = '测量完成，已记录';
      this.saveReading(r);
    } else {
      this.statusText = '正在测量...';
    }
    this.notifyChange();
  }

  /** 保存稳定读数 */
  private async saveReading(r: WeightReading): Promise<void> {
    const bmi = calcBmi(r.weightKg, this.profile.heightCm);
    const comp: BodyComposition = estimateBodyComposition(r.weightKg, this.profile);
    const record: WeightRecord = {
      id: ++this.recordSeq,
      timestamp: r.timestamp,
      weightKg: r.weightKg,
      bmi: bmi,
      bodyFatPercent: r.bodyFatPercent !== undefined ? r.bodyFatPercent : comp.bodyFatPercent,
      impedance: r.impedance,
      source: this.currentAdapterName || '手动录入'
    };
    this.records = await this.store.addRecord(record);
    this.notifyChange();
  }

  /** 手动录入体重（无秤时可直接使用） */
  async addManualWeight(kg: number): Promise<void> {
    if (kg <= 0 || kg > 500) {
      return;
    }
    const reading: WeightReading = {
      weightKg: kg,
      state: ScaleState.STABLE,
      weightType: WeightType.NET,
      timestamp: Date.now(),
      rawUnit: WeightUnit.KG,
      rawValue: kg
    };
    this.currentAdapterName = '手动录入';
    this.liveWeightKg = kg;
    await this.saveReading(reading);
    this.statusText = '已手动记录';
    this.notifyChange();
  }

  /** 更新用户档案并重算全部历史 BMI；返回是否真正落盘 */
  async updateProfile(p: UserProfile): Promise<boolean> {
    // 以现有档案为基底做合并，避免调用方漏传字段把昵称/标准清掉
    const merged: UserProfile = {
      heightCm: p.heightCm > 0 ? p.heightCm : this.profile.heightCm,
      age: p.age > 0 ? p.age : this.profile.age,
      gender: p.gender,
      targetWeightKg: p.targetWeightKg > 0 ? p.targetWeightKg : this.profile.targetWeightKg,
      displayUnit: p.displayUnit,
      bmiStandard: p.bmiStandard,
      nickname: p.nickname,
      avatarUri: typeof p.avatarUri === 'string' ? p.avatarUri : this.profile.avatarUri
    };
    this.profile = merged;
    const saved = await this.store.saveProfile(merged);
    // 身高变化后，历史 BMI 需重算
    const next = this.records.map((r: WeightRecord): WeightRecord => {
      const item: WeightRecord = {
        id: r.id,
        timestamp: r.timestamp,
        weightKg: r.weightKg,
        bmi: calcBmi(r.weightKg, merged.heightCm),
        bodyFatPercent: r.bodyFatPercent,
        impedance: r.impedance,
        source: r.source
      };
      return item;
    });
    await this.store.saveRecords(next);
    this.records = next;
    if (!saved) {
      this.statusText = '档案已在本次生效，但本地保存失败，重启后可能丢失';
    }
    this.notifyChange();
    return saved;
  }

  /** 删除记录 */
  async deleteRecord(id: number): Promise<void> {
    this.records = await this.store.deleteRecord(id);
    this.notifyChange();
  }

  /** 清空记录 */
  async clearRecords(): Promise<void> {
    await this.store.clearRecords();
    this.records = [];
    this.notifyChange();
  }

  /** 导出 CSV */
  exportCsv(): string {
    return this.store.exportCsv(this.records);
  }

  /** 设置主题色索引并持久化（下次启动仍生效） */
  async setThemeColor(index: number): Promise<void> {
    this.themeColorIndex = index;
    await this.store.saveThemeColor(index);
    this.notifyChange();
  }

  /** 设置自定义头像 URI 并持久化；返回是否真正落盘 */
  async setAvatar(uri: string): Promise<boolean> {
    const prev: UserProfile = this.profile;
    const next: UserProfile = {
      heightCm: prev.heightCm,
      age: prev.age,
      gender: prev.gender,
      targetWeightKg: prev.targetWeightKg,
      displayUnit: prev.displayUnit,
      bmiStandard: prev.bmiStandard,
      nickname: prev.nickname,
      avatarUri: uri
    };
    this.profile = next;
    const saved = await this.store.saveProfile(next);
    if (!saved) {
      this.statusText = '头像已选择，但本地保存失败，重启后可能丢失';
    }
    this.notifyChange();
    return saved;
  }

  /** 获取适配器清单 */
  listAdapters(): Array<AdapterInfo> {
    return this.registry.list();
  }

  // ---------- 派生数据（供 UI 展示） ----------

  /** 当前展示体重（按用户偏好单位换算） */
  displayWeight(): string {
    const kg = this.liveWeightKg > 0 ? this.liveWeightKg :
      (this.records.length > 0 ? this.records[0].weightKg : 0);
    if (kg <= 0) {
      return '--.--';
    }
    return convertFromKg(kg, this.profile.displayUnit).toFixed(2);
  }

  /** 单位符号 */
  displayUnitSymbol(): string {
    return unitSymbol(this.profile.displayUnit);
  }

  /** BMI 数值 */
  currentBmi(): number {
    const kg = this.liveWeightKg > 0 ? this.liveWeightKg :
      (this.records.length > 0 ? this.records[0].weightKg : 0);
    return calcBmi(kg, this.profile.heightCm);
  }

  /** BMI 分级（按用户在档案中选择的标准） */
  bmiClassification(): BmiClassification {
    const standard = this.profile.bmiStandard === BmiStandardChoice.WHO ?
      BmiStandard.WHO : BmiStandard.CHINA;
    return classifyBmi(this.currentBmi(), standard);
  }

  /** 当前 BMI 标准说明文案 */
  bmiStandardText(): string {
    return this.profile.bmiStandard === BmiStandardChoice.WHO ?
      'WHO 标准：18.5 / 25 / 30' : '中国标准：18.5 / 24 / 28';
  }

  /** 理想体重区间（展示单位） */
  idealWeightText(): string {
    const range = idealWeightRangeKg(this.profile.heightCm);
    const min = convertFromKg(range.min, this.profile.displayUnit);
    const max = convertFromKg(range.max, this.profile.displayUnit);
    return `${min.toFixed(1)} ~ ${max.toFixed(1)} ${unitSymbol(this.profile.displayUnit)}`;
  }

  /** 身体成分估算 */
  bodyComposition(): BodyComposition | null {
    const kg = this.liveWeightKg > 0 ? this.liveWeightKg :
      (this.records.length > 0 ? this.records[0].weightKg : 0);
    if (kg <= 0) {
      return null;
    }
    return estimateBodyComposition(kg, this.profile);
  }

  /** 目标建议 */
  adviceText(): string {
    const kg = this.liveWeightKg > 0 ? this.liveWeightKg :
      (this.records.length > 0 ? this.records[0].weightKg : 0);
    return weightAdvice(kg, this.profile.targetWeightKg);
  }

  /** 相较上次称重的差值（kg） */
  weightDeltaKg(): number | null {
    if (this.records.length < 2) {
      return null;
    }
    return this.records[0].weightKg - this.records[1].weightKg;
  }

  /** 「我的」页：最近一次有效体重（kg），无记录时返回 0 */
  latestWeightKg(): number {
    return this.records.length > 0 ? this.records[0].weightKg : 0;
  }

  /** 「我的」页：距目标体重还差多少 kg（正数表示仍需减重） */
  distanceToTargetKg(): number | null {
    const kg = this.latestWeightKg();
    if (kg <= 0) {
      return null;
    }
    return Math.round((kg - this.profile.targetWeightKg) * 100) / 100;
  }

  /** 「我的」页：累计称重次数 */
  recordCount(): number {
    return this.records.length;
  }

  private notifyChange(): void {
    if (this.onChange) {
      this.onChange();
    }
  }
}
