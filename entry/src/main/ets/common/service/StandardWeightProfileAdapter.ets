/**
 * 标准 BLE Weight Scale 协议适配器
 *
 * 遵循 Bluetooth SIG 的 Weight Scale Profile：
 * - 服务 Weight Scale (0x181D)，特征 Weight Measurement (0x2A9D)
 * - 服务 Body Composition (0x181B)，特征 Body Composition Measurement (0x2A9C)
 * - 服务 User Data (0x181C)，身高 0x2A8E
 * - 服务 Current Time (0x1805)，特征 0x2A2B
 *
 * Weight Measurement (0x2A9D) 帧格式：
 *   偏移  长度  字段
 *   0     1     Flags
 *   1     2     Weight (uint16)，SI 单位为千克、分辨率 0.005 kg；Imperial 为磅、分辨率 0.01 lb
 *   3     7     Time Stamp（可选，Flags bit1=1 时存在）
 *   10    1     User ID（可选，Flags bit2=1 时存在）
 *   11    2     BMI（可选，Flags bit3=1 时存在，uint10，可带小数）
 *   13    2     Height（可选，Flags bit3=1 时存在，SI 为米、分辨率 0.001 m）
 *
 * Body Composition Measurement (0x2A9C) 帧格式：
 *   0     1     Flags
 *   1     2     Body Fat Percent（uint16，分辨率 0.1%）
 *   3     2     Lean Body Mass（可选，分辨率 0.1 kg）
 *   ...  2     Body Water Percent（可选，0.1%）
 *   ...  2     Skeletal Muscle Percent（可选，0.1%）
 *   ...  2     Bone Mass（可选，0.1 kg）
 *   ...  2     Impedance（可选，uint16 Ω）
 */

import { ScaleState, WeightReading, WeightType, WeightUnit } from '../model/ScaleModels';
import { readUint16LE, readUint16BE } from '../util/ByteUtils';
import { CharacteristicRef, ProtocolAdapter, ServiceRef } from './ProtocolAdapter';

/** 标准服务/特征 UUID */
export const UUID_WEIGHT_SCALE_SERVICE = '0000181d-0000-1000-8000-00805f9b34fb';
export const UUID_WEIGHT_MEASUREMENT = '00002a9d-0000-1000-8000-00805f9b34fb';
export const UUID_BODY_COMPOSITION_SERVICE = '0000181b-0000-1000-8000-00805f9b34fb';
export const UUID_BODY_COMPOSITION_MEASUREMENT = '00002a9c-0000-1000-8000-00805f9b34fb';
export const UUID_USER_DATA_SERVICE = '0000181c-0000-1000-8000-00805f9b34fb';
export const UUID_USER_HEIGHT = '00002a8e-0000-1000-8000-00805f9b34fb';
export const UUID_CURRENT_TIME_SERVICE = '00001805-0000-1000-8000-00805f9b34fb';
export const UUID_CURRENT_TIME = '00002a2b-0000-1000-8000-00805f9b34fb';
export const UUID_BATTERY_SERVICE = '0000180f-0000-1000-8000-00805f9b34fb';
export const UUID_BATTERY_LEVEL = '00002a19-0000-1000-8000-00805f9b34fb';

export class StandardWeightProfileAdapter implements ProtocolAdapter {
  readonly id: string = 'standard';
  readonly displayName: string = '标准蓝牙体重秤 (BLE Weight Scale Profile)';

  /** 上一次解析出的体成分数据，等待与体重合并 */
  private pendingBodyFat: number | undefined = undefined;
  private pendingImpedance: number | undefined = undefined;
  private pendingLeanMass: number | undefined = undefined;
  private pendingMuscle: number | undefined = undefined;
  private pendingWater: number | undefined = undefined;
  private pendingBone: number | undefined = undefined;
  /** 设备上报的高度（米），用于 BMI */
  private deviceHeightM: number | undefined = undefined;

  matchDevice(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): boolean {
    // 标准协议没有固定设备名，靠广播的服务 UUID 判定
    const lower = serviceUuids.map((u: string) => u.toLowerCase());
    return lower.some((u: string) =>
      u.indexOf('181d') >= 0 || u.indexOf('181b') >= 0 || u.indexOf('0000181d-0000-1000-8000-00805f9b34fb') >= 0);
  }

  onServicesDiscovered(services: ServiceRef[]): string[] {
    const subscribe: string[] = [];
    for (const svc of services) {
      const uuid = svc.serviceUuid.toLowerCase();
      // 体重测量
      if (uuid.indexOf('181d') >= 0 || uuid.indexOf('0000181d-0000-1000-8000-00805f9b34fb') >= 0) {
        const ch = this.findCharacteristic(svc, UUID_WEIGHT_MEASUREMENT);
        if (ch) {
          subscribe.push(ch.characteristicUuid);
        }
      }
      // 体成分
      if (uuid.indexOf('181b') >= 0 || uuid.indexOf('0000181b-0000-1000-8000-00805f9b34fb') >= 0) {
        const ch = this.findCharacteristic(svc, UUID_BODY_COMPOSITION_MEASUREMENT);
        if (ch) {
          subscribe.push(ch.characteristicUuid);
        }
      }
    }
    return subscribe;
  }

  onNotification(characteristicUuid: string, data: Uint8Array): WeightReading | null {
    const uuid = characteristicUuid.toLowerCase();
    if (uuid.indexOf('2a9d') >= 0) {
      return this.parseWeightMeasurement(data);
    }
    if (uuid.indexOf('2a9c') >= 0) {
      this.parseBodyComposition(data);
      return null; // 体成分数据需要等体重帧合并
    }
    if (uuid.indexOf('2a8e') >= 0) {
      // 用户身高：uint16，单位厘米（按 UDS 规范）
      this.deviceHeightM = readUint16LE(data, 0) / 100.0;
      return null;
    }
    return null;
  }

  onCharacteristicRead(characteristicUuid: string, data: Uint8Array): WeightReading | null {
    return this.onNotification(characteristicUuid, data);
  }

  /**
   * 解析 Weight Measurement (0x2A9D)
   */
  private parseWeightMeasurement(d: Uint8Array): WeightReading | null {
    if (d.length < 3) {
      return null;
    }
    const flags = d[0];
    const imperial = (flags & 0x01) !== 0;
    const hasTimestamp = (flags & 0x02) !== 0;
    const hasUserId = (flags & 0x04) !== 0;
    const hasBmiHeight = (flags & 0x08) !== 0;

    // SI 单位：kg，分辨率 0.005；Imperial：lb，分辨率 0.01
    const raw = readUint16LE(d, 1);
    let weightKg: number;
    let rawUnit: WeightUnit;
    let rawValue: number;
    if (imperial) {
      rawUnit = WeightUnit.LB;
      rawValue = raw * 0.01;
      weightKg = rawValue * 0.45359237;
    } else {
      rawUnit = WeightUnit.KG;
      rawValue = raw * 0.005;
      weightKg = rawValue;
    }

    let timestamp: number = Date.now();
    let offset = 3;
    if (hasTimestamp && d.length >= offset + 7) {
      const year = readUint16LE(d, offset);
      const month = d[offset + 2];
      const day = d[offset + 3];
      const hours = d[offset + 4];
      const minutes = d[offset + 5];
      const seconds = d[offset + 6];
      const t = new Date(year, month - 1, day, hours, minutes, seconds);
      if (!isNaN(t.getTime())) {
        timestamp = t.getTime();
      }
      offset += 7;
    }
    if (hasUserId) {
      offset += 1;
    }

    // BMI（uint10）与 Height（uint16）
    let deviceBmi: number | undefined = undefined;
    if (hasBmiHeight && d.length >= offset + 4) {
      const bmiRaw = readUint16LE(d, offset) & 0x03FF;
      deviceBmi = bmiRaw / 10.0;
      const hRaw = readUint16LE(d, offset + 2);
      // SI：米，分辨率 0.001；Imperial：英寸，分辨率 0.1
      if (!imperial) {
        this.deviceHeightM = hRaw * 0.001;
      }
      offset += 4;
    }

    // 有效范围判断：合理体重区间（1g ~ 300kg），超出视为无效读数
    if (weightKg <= 0 || weightKg > 300) {
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

    // 合并体成分数据
    if (this.pendingBodyFat !== undefined) {
      reading.bodyFatPercent = this.pendingBodyFat;
      this.pendingBodyFat = undefined;
    }
    if (this.pendingImpedance !== undefined) {
      reading.impedance = this.pendingImpedance;
      this.pendingImpedance = undefined;
    }
    if (this.pendingLeanMass !== undefined) {
      reading.leanBodyMassKg = this.pendingLeanMass;
      this.pendingLeanMass = undefined;
    }
    if (this.pendingMuscle !== undefined) {
      reading.skeletalMuscleKg = this.pendingMuscle;
      this.pendingMuscle = undefined;
    }
    if (this.pendingWater !== undefined) {
      reading.bodyWaterPercent = this.pendingWater;
      this.pendingWater = undefined;
    }
    if (this.pendingBone !== undefined) {
      reading.boneMassKg = this.pendingBone;
      this.pendingBone = undefined;
    }
    return reading;
  }

  /**
   * 解析 Body Composition Measurement (0x2A9C)
   */
  private parseBodyComposition(d: Uint8Array): void {
    if (d.length < 3) {
      return;
    }
    const flags = d[0];
    // bit0: Body Fat Percent 是否存在；bit1: Lean Body Mass；bit2: Body Water；
    // bit3: Skeletal Muscle；bit4: Bone Mass；bit5: Impedance
    let offset = 1;
    if ((flags & 0x01) !== 0) {
      this.pendingBodyFat = readUint16LE(d, offset) * 0.1;
      offset += 2;
    }
    if ((flags & 0x02) !== 0) {
      this.pendingLeanMass = readUint16LE(d, offset) * 0.1;
      offset += 2;
    }
    if ((flags & 0x04) !== 0) {
      this.pendingWater = readUint16LE(d, offset) * 0.1;
      offset += 2;
    }
    if ((flags & 0x08) !== 0) {
      this.pendingMuscle = readUint16LE(d, offset) * 0.1;
      offset += 2;
    }
    if ((flags & 0x10) !== 0) {
      this.pendingBone = readUint16LE(d, offset) * 0.1;
      offset += 2;
    }
    if ((flags & 0x20) !== 0) {
      this.pendingImpedance = readUint16LE(d, offset);
      offset += 2;
    }
  }

  /** 设备上报的身高（米），若设备支持 */
  getDeviceHeightM(): number | undefined {
    return this.deviceHeightM;
  }

  onDisconnected(): void {
    this.pendingBodyFat = undefined;
    this.pendingImpedance = undefined;
    this.pendingLeanMass = undefined;
    this.pendingMuscle = undefined;
    this.pendingWater = undefined;
    this.pendingBone = undefined;
    this.deviceHeightM = undefined;
  }

  private findCharacteristic(svc: ServiceRef, uuid: string): CharacteristicRef | undefined {
    for (const ch of svc.characteristics) {
      if (ch.characteristicUuid.toLowerCase() === uuid.toLowerCase()) {
        return ch;
      }
    }
    return undefined;
  }
}
