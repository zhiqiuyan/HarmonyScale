/**
 * 广播型体重秤适配器（无需建立 GATT 连接）
 *
 * 覆盖三诺 Sinocare / IFIT / 部分乐心、香山方案。这类秤直接把体重放进
 * BLE 广播的 Manufacturer Specific Data 中，手机扫描即可读数。
 *
 * 帧格式（Manufacturer Data）：
 *   长度 > 16
 *   偏移 9   = 重量低字节
 *   偏移 10  = 重量高字节（uint16 大端，分辨率 0.01 kg）
 *   偏移 16  = XOR 校验和（对偏移 6..15 逐字节异或）
 *
 * 稳定性判定：同一重量连续出现 N 次（默认 9 次）才认为读数锁定，
 * 避免把上秤过程中的抖动值记录入库。
 */

import { ScaleState, WeightReading, WeightType, WeightUnit } from '../model/ScaleModels';
import { readUint16BE } from '../util/ByteUtils';
import { ProtocolAdapter, ServiceRef } from './ProtocolAdapter';

/** 连续相同读数的稳定阈值 */
const STABLE_THRESHOLD: number = 9;

export class BroadcastScaleAdapter implements ProtocolAdapter {
  readonly id: string = 'broadcast-scale';
  readonly displayName: string = '广播型体重秤 (三诺 / IFIT / 通用广播方案)';

  private lastWeightRaw: number = 0;
  private repeatCount: number = 0;
  private publishedRaw: number = -1;

  matchDevice(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): boolean {
    const name = (deviceName || '').toLowerCase();
    if (name === 'weight scale' || name === 'ifit' || name.indexOf('sinocare') >= 0) {
      return true;
    }
    // 通用判定：manufacturer data 长度与校验和均符合该帧格式
    return this.parseFrame(manufacturerData) !== null;
  }

  requiresConnection(): boolean {
    return false;
  }

  onServicesDiscovered(services: ServiceRef[]): string[] {
    // 广播型秤不需要连接，无特征订阅
    return [];
  }

  onNotification(characteristicUuid: string, data: Uint8Array): WeightReading | null {
    return null;
  }

  onAdvertisement(deviceName: string, manufacturerData: Uint8Array,
    serviceData: Uint8Array): WeightReading | null {
    const raw = this.parseFrame(manufacturerData);
    if (raw === null) {
      return null;
    }

    // 稳定性计数
    if (raw === this.lastWeightRaw) {
      this.repeatCount += 1;
    } else {
      this.lastWeightRaw = raw;
      this.repeatCount = 1;
      this.publishedRaw = -1;
    }

    if (this.repeatCount < STABLE_THRESHOLD) {
      return null;
    }
    if (this.publishedRaw === raw) {
      return null; // 同一次称重只记录一次
    }
    this.publishedRaw = raw;

    const weightKg = raw / 100.0;
    if (weightKg <= 0.5 || weightKg > 300) {
      return null;
    }
    return {
      weightKg: weightKg,
      state: ScaleState.STABLE,
      weightType: WeightType.NET,
      timestamp: Date.now(),
      rawUnit: WeightUnit.KG,
      rawValue: weightKg
    };
  }

  /**
   * 解析广播帧并校验；返回重量原始值，无效返回 null
   */
  private parseFrame(d: Uint8Array): number | null {
    if (!d || d.length <= 16) {
      return null;
    }
    let checksum = 0;
    for (let i = 6; i <= 15; i++) {
      checksum ^= d[i];
    }
    if ((checksum & 0xFF) !== d[16]) {
      return null;
    }
    // 注意：重量高字节在 10、低字节在 9，与标准大端顺序相反
    const hi = d[10] & 0xFF;
    const lo = d[9] & 0xFF;
    const raw = (hi << 8) | lo;
    if (raw <= 0) {
      return null;
    }
    return raw;
  }

  onDisconnected(): void {
    this.lastWeightRaw = 0;
    this.repeatCount = 0;
    this.publishedRaw = -1;
  }
}
