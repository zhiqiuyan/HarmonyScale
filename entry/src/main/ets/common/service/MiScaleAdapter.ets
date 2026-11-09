/**
 * 小米体重秤适配器（Mi Scale v1 / Mi Body Composition Scale v2）
 *
 * 设备识别：广播名 "MI SCALE2" / "MIBCS" / "MIBFS" / "MI_SCALE*"
 *
 * 服务与特征：
 * - v1 主服务 Weight Scale (0x181D)，历史/时间在其下
 * - v2 主服务 Body Composition (0x181B)，历史/时间在其下
 * - 厂商历史流特征 00002a2f-0000-3512-2118-0009af100700（notify + 写控制）
 * - 厂商配置服务 00001530-…，特征 00001542-…（仅 v2，用于单位设置）
 *
 * 帧格式：
 * 【10 字节历史帧】
 *   偏移  长度  字段
 *   0     1     status：bit0=磅，bit4=市斤，bit5=稳定，bit7=移除
 *   1     2     weight（uint16 LE）：kg 时 /200，磅或市斤时 /100
 *   3     2     年份（uint16 LE）
 *   5     1     月
 *   6     1     日
 *   7     1     时
 *   8     1     分
 *
 * 【13 字节实时帧】
 *   偏移  长度  字段
 *   0     1     flags0：bit0=磅
 *   1     1     flags1：bit5=稳定，bit6=市斤，bit7=移除，bit2=含阻抗
 *   2     2     年份（uint16 LE）
 *   4     1     月
 *   5     1     日
 *   6     1     时
 *   7     1     分
 *   9     2     阻抗（uint16 LE，Ω）
 *   11    2     weight（uint16 LE）：kg 时 /200，磅或市斤时 /100
 */

import { ScaleState, WeightReading, WeightType, WeightUnit } from '../model/ScaleModels';
import { readUint16LE } from '../util/ByteUtils';
import { CharacteristicRef, ProtocolAdapter, ServiceRef } from './ProtocolAdapter';

export const UUID_MI_BODY_COMP_SERVICE = '0000181b-0000-1000-8000-00805f9b34fb';
export const UUID_MI_WEIGHT_SERVICE = '0000181d-0000-1000-8000-00805f9b34fb';
export const UUID_MI_HISTORY_CHAR = '00002a2f-0000-3512-2118-0009af100700';
export const UUID_MI_CONFIG_SERVICE = '00001530-0000-3512-2118-0009af100700';
export const UUID_MI_CONFIG_CHAR = '00001542-0000-3512-2118-0009af100700';

export class MiScaleAdapter implements ProtocolAdapter {
  readonly id: string = 'mi-scale';
  readonly displayName: string = '小米体重秤 (Mi Scale / Mi Body)';

  /** 上报的阻抗值，等待与体重合并 */
  private pendingImpedance: number | undefined = undefined;

  matchDevice(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): boolean {
    const name = (deviceName || '').toUpperCase();
    if (name.indexOf('MIBCS') === 0 || name.indexOf('MIBFS') === 0 ||
      name === 'MI SCALE2' || name.indexOf('MI_SCALE') === 0) {
      return true;
    }
    // 也可通过厂商服务 UUID 识别
    const lower = serviceUuids.map((u: string) => u.toLowerCase());
    return lower.some((u: string) => u.indexOf('00001530-0000-3512-2118-0009af100700') >= 0);
  }

  onServicesDiscovered(services: ServiceRef[]): string[] {
    const subscribe: string[] = [];
    for (const svc of services) {
      const ch = this.findByUuid(svc.characteristics, UUID_MI_HISTORY_CHAR);
      if (ch) {
        subscribe.push(ch.characteristicUuid);
      }
    }
    return subscribe;
  }

  onNotification(characteristicUuid: string, data: Uint8Array): WeightReading | null {
    const uuid = characteristicUuid.toLowerCase();
    if (uuid.indexOf('00002a2f') >= 0) {
      return this.parseFrame(data);
    }
    // 部分固件从标准 0x2A9D 推送
    if (uuid.indexOf('2a9d') >= 0) {
      return this.parseFrame(data);
    }
    return null;
  }

  onCharacteristicRead(characteristicUuid: string, data: Uint8Array): WeightReading | null {
    return this.onNotification(characteristicUuid, data);
  }

  /**
   * 解析小米帧，自动区分 10 字节与 13 字节格式
   */
  private parseFrame(d: Uint8Array): WeightReading | null {
    if (d.length === 10) {
      return this.parseHistory10(d);
    }
    if (d.length === 13) {
      return this.parseLive13(d);
    }
    return null;
  }

  /** 10 字节历史帧 */
  private parseHistory10(d: Uint8Array): WeightReading | null {
    if (d.length < 10) {
      return null;
    }
    const status = d[0];
    const isLbs = (status & 0x01) !== 0;
    const isCatty = (status & 0x10) !== 0;
    const stable = (status & 0x20) !== 0;
    const removed = (status & 0x80) !== 0;

    if (!stable || removed) {
      return null;
    }

    const weightRaw = readUint16LE(d, 1);
    const native = (isLbs || isCatty) ? weightRaw / 100.0 : weightRaw / 200.0;

    const year = readUint16LE(d, 3);
    const month = d[5];
    const day = d[6];
    const hour = d[7];
    const minute = d[8];

    const timestamp = this.buildTimestamp(year, month, day, hour, minute);
    if (timestamp <= 0) {
      return null;
    }

    return this.buildReading(native, isLbs, isCatty, timestamp);
  }

  /** 13 字节实时帧 */
  private parseLive13(d: Uint8Array): WeightReading | null {
    if (d.length < 13) {
      return null;
    }
    const c0 = d[0];
    const c1 = d[1];
    const isLbs = (c0 & 0x01) !== 0;
    const isCatty = (c1 & 0x40) !== 0;
    const stable = (c1 & 0x20) !== 0;
    const removed = (c1 & 0x80) !== 0;
    const hasImp = (c1 & 0x02) !== 0;

    if (!stable || removed) {
      return null;
    }

    const year = readUint16LE(d, 2);
    const month = d[4];
    const day = d[5];
    const hour = d[6];
    const minute = d[7];

    const weightRaw = readUint16LE(d, 11);
    const native = (isLbs || isCatty) ? weightRaw / 100.0 : weightRaw / 200.0;

    let impedance: number | undefined = undefined;
    if (hasImp) {
      const imp = readUint16LE(d, 9);
      if (imp > 0) {
        impedance = imp;
        this.pendingImpedance = imp;
      }
    }

    const timestamp = this.buildTimestamp(year, month, day, hour, minute);
    if (timestamp <= 0) {
      return null;
    }

    const reading = this.buildReading(native, isLbs, isCatty, timestamp);
    if (reading === null) {
      return null;
    }
    if (impedance !== undefined) {
      reading.impedance = impedance;
    }
    return reading;
  }

  /** 构造统一读数并做合理性校验 */
  private buildReading(native: number, isLbs: boolean, isCatty: boolean, timestamp: number): WeightReading | null {
    if (!isFinite(native) || native <= 0) {
      return null;
    }
    // 统一换算为千克
    let weightKg: number;
    let rawUnit: WeightUnit;
    let rawValue: number;
    if (isCatty) {
      // 市斤 = 0.5 kg
      rawUnit = WeightUnit.KG;
      rawValue = native;
      weightKg = native * 0.5;
    } else if (isLbs) {
      rawUnit = WeightUnit.LB;
      rawValue = native;
      weightKg = native * 0.45359237;
    } else {
      rawUnit = WeightUnit.KG;
      rawValue = native;
      weightKg = native;
    }

    if (weightKg <= 0.5 || weightKg > 300) {
      return null;
    }

    const reading: WeightReading = {
      weightKg: weightKg,
      state: ScaleState.STABLE,
      weightType: WeightType.NET,
      timestamp: timestamp,
      rawUnit: rawUnit,
      rawValue: rawValue
    };
    if (this.pendingImpedance !== undefined) {
      reading.impedance = this.pendingImpedance;
      this.pendingImpedance = undefined;
    }
    return reading;
  }

  /** 由年月日时分构造时间戳，非法返回 0 */
  private buildTimestamp(year: number, month: number, day: number, hour: number, minute: number): number {
    if (year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31) {
      return 0;
    }
    const t = new Date(year, month - 1, day, hour, minute, 0, 0);
    const ts = t.getTime();
    if (isNaN(ts)) {
      return 0;
    }
    // 与当前时间相差过大视为异常数据
    const now = Date.now();
    const diff = Math.abs(now - ts);
    if (diff > 20 * 365 * 24 * 3600 * 1000) {
      return 0;
    }
    return ts;
  }

  onDisconnected(): void {
    this.pendingImpedance = undefined;
  }

  private findByUuid(list: CharacteristicRef[], uuid: string): CharacteristicRef | undefined {
    for (const ch of list) {
      if (ch.characteristicUuid.toLowerCase() === uuid.toLowerCase()) {
        return ch;
      }
    }
    return undefined;
  }
}
