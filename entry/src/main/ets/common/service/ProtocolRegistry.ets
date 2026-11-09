/**
 * 协议适配器注册表
 *
 * 维护所有已实现的体重秤协议，负责：
 * 1. 扫描阶段按名称/广播识别设备，选出最匹配的适配器
 * 2. 提供「自动识别」与「手动指定」两种模式
 *
 * 新增厂商适配器只需在 createDefaultAdapters() 中注册，界面层与连接层无需改动。
 */

import { ProtocolAdapter } from './ProtocolAdapter';
import { StandardWeightProfileAdapter } from './StandardWeightProfileAdapter';
import { MiScaleAdapter } from './MiScaleAdapter';
import { YunmaiAdapter } from './YunmaiAdapter';
import { QNScaleAdapter } from './QNScaleAdapter';
import { VScaleAdapter } from './VScaleAdapter';
import { BroadcastScaleAdapter } from './BroadcastScaleAdapter';
import { ScalesBridgeTextAdapter } from './ScalesBridgeTextAdapter';

/** 适配器工厂：每次连接返回新实例，避免多设备间状态串扰 */
export type AdapterFactory = () => ProtocolAdapter;

/** 适配器摘要（供 UI 展示） */
export interface AdapterInfo {
  id: string;
  /** 协议全名，用于连接状态、记录来源等需要完整语义的场景 */
  displayName: string;
  /** 品牌短名，用于标签（Tag）等窄空间；避免中英文长串造成阅读压力 */
  shortName: string;
}

/** 已注册的适配器条目 */
export interface AdapterEntry {
  id: string;
  displayName: string;
  shortName: string;
  factory: AdapterFactory;
  /** 匹配优先级，数值越小越优先（精确协议优先于通用协议） */
  priority: number;
}

/**
 * 默认适配器清单
 *
 * 顺序即优先级：
 * - 厂商专有协议在前（名字/UUID 精确匹配）
 * - 通用透传与标准协议在后（作为兜底）
 */
export function createDefaultAdapters(): AdapterEntry[] {
  return [
    { id: 'mi-scale', displayName: '小米体重秤 (Mi Scale / Mi Body)', shortName: '小米体重秤', factory: (): MiScaleAdapter => new MiScaleAdapter(), priority: 10 },
    { id: 'yunmai', displayName: '云麦好轻体脂秤', shortName: '云麦好轻', factory: (): YunmaiAdapter => new YunmaiAdapter(), priority: 20 },
    { id: 'vscale', displayName: 'VScale / Exingtech Y1', shortName: 'VScale', factory: (): VScaleAdapter => new VScaleAdapter(), priority: 30 },
    { id: 'qn-scale', displayName: 'QN Scale 系列 (FITINDEX / Renpho / 香山等)', shortName: 'QN Scale', factory: (): QNScaleAdapter => new QNScaleAdapter(), priority: 40 },
    { id: 'broadcast-scale', displayName: '广播型体重秤 (三诺 / IFIT)', shortName: '广播型体脂秤', factory: (): BroadcastScaleAdapter => new BroadcastScaleAdapter(), priority: 50 },
    { id: 'scales-bridge-text', displayName: 'scales-bridge 文本协议', shortName: 'scales-bridge', factory: (): ScalesBridgeTextAdapter => new ScalesBridgeTextAdapter(), priority: 60 },
    { id: 'standard', displayName: '标准 BLE 体重秤 (通用)', shortName: '标准 BLE 体重秤', factory: (): StandardWeightProfileAdapter => new StandardWeightProfileAdapter(), priority: 90 }
  ];
}

/**
 * 协议注册表
 */
export class ProtocolRegistry {
  private entries: AdapterEntry[] = [];

  constructor(entries: AdapterEntry[] = createDefaultAdapters()) {
    this.entries = entries.slice();
    this.entries.sort((a: AdapterEntry, b: AdapterEntry) => a.priority - b.priority);
  }

  /**
   * 获取所有已注册适配器摘要
   */
  list(): Array<AdapterInfo> {
    return this.entries.map((e: AdapterEntry): AdapterInfo => {
      const info: AdapterInfo = { id: e.id, displayName: e.displayName, shortName: e.shortName };
      return info;
    });
  }

  /**
   * 按 id 创建适配器实例
   */
  create(id: string): ProtocolAdapter | null {
    for (const e of this.entries) {
      if (e.id === id) {
        return e.factory();
      }
    }
    return null;
  }

  /**
   * 自动识别：返回第一个匹配该设备的适配器 id
   * @param deviceName 广播名
   * @param serviceUuids 广播携带的服务 UUID
   * @param manufacturerData 厂商数据
   * @param serviceData 服务数据
   */
  identify(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): string | null {
    for (const e of this.entries) {
      const adapter = e.factory();
      if (adapter.matchDevice(deviceName, serviceUuids, manufacturerData, serviceData)) {
        return e.id;
      }
    }
    return null;
  }

  /**
   * 判断某设备是否可能是体重秤（用于扫描列表过滤）
   */
  isScaleCandidate(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): boolean {
    return this.identify(deviceName, serviceUuids, manufacturerData, serviceData) !== null;
  }
}
