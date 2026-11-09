/**
 * QN Scale 系列适配器（FITINDEX / Renpho / 香山 / 1byone 等大量国产出海体脂秤共用方案）
 *
 * GATT 分两种型号：
 * - Type 1：服务 0xFFE0，通知 0xFFE1，杂项指示 0xFFE2，写配置 0xFFE3，写时间 0xFFE4
 * - Type 2：服务 0xFFF0，通知 0xFFF1，写共享 0xFFF2
 *
 * 实时体重帧（opcode 0x10）：
 *   偏移 0   = 0x10
 *   偏移 1   = 长度
 *   偏移 2   = 协议类型（回复时需回显）
 *   偏移 3,4 = 重量（uint16 BE），通常 /100 kg，部分型号 /10
 *   偏移 5   = 稳定标志（1 = 稳定）
 *   偏移 6,7 = 阻抗 R1（uint16 BE）
 *   偏移 8,9 = 阻抗 R2（uint16 BE）
 *
 * ES-30M 变体：偏移 4 = 稳定状态（2 = 完成），偏移 5,6 = 重量，7,8 / 9,10 = 阻抗
 */

import { ScaleState, WeightReading, WeightType, WeightUnit } from '../model/ScaleModels';
import { readUint16BE } from '../util/ByteUtils';
import { ProtocolAdapter, ServiceRef } from './ProtocolAdapter';

/** 通知特征 UUID 片段 */
const NOTIFY_UUIDS: string[] = ['ffe1', 'fff1'];

export class QNScaleAdapter implements ProtocolAdapter {
  readonly id: string = 'qn-scale';
  readonly displayName: string = 'QN Scale 系列 (FITINDEX / Renpho / 香山等)';

  /** 本次会话是否已发布过稳定读数，避免重复记录 */
  private published: boolean = false;
  /** 重量缩放系数，默认 /100，检测异常时回退 /10 */
  private weightScaleFactor: number = 100;
  /** 上一次稳定帧的协议类型，用于回复 ACK */
  private seenProtocolType: number = 0;

  matchDevice(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): boolean {
    const lower = serviceUuids.map((u: string) => u.toLowerCase());
    if (lower.some((u: string) => u.indexOf('ffe0') >= 0 || u.indexOf('fff0') >= 0 ||
      u.indexOf('0000ffe0-') >= 0 || u.indexOf('0000fff0-') >= 0)) {
      return true;
    }
    const name = (deviceName || '').toUpperCase();
    const known = ['QN', 'FITINDEX', 'RENPHO', 'ES-', '1BYONE', 'Etekcity', 'SENSSUN'];
    for (const k of known) {
      if (name.indexOf(k) >= 0) {
        return true;
      }
    }
    return false;
  }

  onServicesDiscovered(services: ServiceRef[]): string[] {
    const list: string[] = [];
    for (const svc of services) {
      const s = svc.serviceUuid.toLowerCase();
      if (s.indexOf('ffe0') >= 0 || s.indexOf('fff0') >= 0) {
        for (const ch of svc.characteristics) {
          const c = ch.characteristicUuid.toLowerCase();
          if (NOTIFY_UUIDS.some((u: string) => c.indexOf(u) >= 0)) {
            list.push(ch.characteristicUuid);
          }
        }
      }
    }
    return list;
  }

  onNotification(characteristicUuid: string, data: Uint8Array): WeightReading | null {
    const uuid = characteristicUuid.toLowerCase();
    if (!NOTIFY_UUIDS.some((u: string) => uuid.indexOf(u) >= 0)) {
      return null;
    }
    if (data.length < 10 || data[0] !== 0x10) {
      return null;
    }
    if (this.seenProtocolType === 0) {
      this.seenProtocolType = data[2];
    }

    // 格式判定：偏移 4 ≤ 2 且当前缩放系数为 /10 时，按 ES-30M 变体解析
    const byte4 = data[4];
    let stable: boolean;
    let raw: number;
    let impedance: number = 0;

    if (byte4 <= 0x02 && this.weightScaleFactor === 10) {
      if (data.length < 11) {
        return null;
      }
      stable = byte4 === 0x02 || byte4 === 0x01;
      raw = readUint16BE(data, 5);
      impedance = readUint16BE(data, 7);
    } else {
      stable = data[5] === 1;
      raw = readUint16BE(data, 3);
      impedance = readUint16BE(data, 6);
    }

    if (!stable || this.published) {
      return null;
    }

    let weightKg = raw / this.weightScaleFactor;
    // 启发式回退：某些厂商在握手完成前就上报 /10 的数据
    if ((weightKg < 1 || weightKg > 300) && this.weightScaleFactor === 100) {
      const alt = raw / 10.0;
      if (alt >= 1 && alt <= 300) {
        this.weightScaleFactor = 10;
        weightKg = alt;
      }
    }
    if (weightKg <= 0.5 || weightKg > 300) {
      return null;
    }

    this.published = true;
    const reading: WeightReading = {
      weightKg: weightKg,
      state: ScaleState.STABLE,
      weightType: WeightType.NET,
      timestamp: Date.now(),
      rawUnit: WeightUnit.KG,
      rawValue: weightKg
    };
    if (impedance > 0 && impedance < 10000) {
      reading.impedance = impedance;
    }
    return reading;
  }

  onDisconnected(): void {
    this.published = false;
    this.seenProtocolType = 0;
    this.weightScaleFactor = 100;
  }
}
