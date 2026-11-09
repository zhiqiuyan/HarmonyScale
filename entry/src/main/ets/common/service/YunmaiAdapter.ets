/**
 * 云麦（Yunmai）好轻系列体脂秤适配器
 *
 * 识别：广播名前缀 YUNMAI-SIGNAL / YUNMAI-ISM / YUNMAI-ISC2P / YUNMAI-ISSE / YUNMAI-Scale-3
 *
 * GATT：
 * - 测量服务 0xFFE0，特征 0xFFE4（notify）
 * - 命令服务 0xFFE5，特征 0xFFE9（write）
 *
 * 连接后必须依次写入：用户档案包、时间同步包、启动测量包，秤才会上报数据。
 *
 * 最终帧（≥18 字节）：
 *   偏移 3   = 0x02 表示测量完成（其他值为实时不稳定读数，丢弃）
 *   偏移 5   = Unix 时间戳（uint32 BE）
 *   偏移 9   = 用户 ID（uint32 BE）
 *   偏移 13  = 重量（uint16 BE，分辨率 0.01 kg）
 *   偏移 15  = 阻抗（uint16 BE，Mini 型号）
 *   偏移 17  = 体脂率（部分型号）
 */

import { ScaleState, WeightReading, WeightType, WeightUnit } from '../model/ScaleModels';
import { readUint16BE, readUint32BE } from '../util/ByteUtils';
import { CharacteristicRef, PendingWrite, ProtocolAdapter, ServiceRef } from './ProtocolAdapter';

/** 云麦服务与特征 UUID（16 位 UUID 扩展为 128 位） */
const SVC_MEAS = '0000ffe0-0000-1000-8000-00805f9b34fb';
const CHR_MEAS = '0000ffe4-0000-1000-8000-00805f9b34fb';
const SVC_CMD = '0000ffe5-0000-1000-8000-00805f9b34fb';
const CHR_CMD = '0000ffe9-0000-1000-8000-00805f9b34fb';

/**
 * XOR 校验：从 start 到 endExclusive-1 逐字节异或
 */
function xorChecksum(bytes: Uint8Array, start: number, endExclusive: number): number {
  let v = 0;
  for (let i = start; i < endExclusive && i < bytes.length; i++) {
    v ^= bytes[i];
  }
  return v & 0xFF;
}

export class YunmaiAdapter implements ProtocolAdapter {
  readonly id: string = 'yunmai';
  readonly displayName: string = '云麦好轻体脂秤 (Yunmai)';

  /** 用户 ID，默认 1 */
  private userId: number = 1;
  private heightCm: number = 170;
  private age: number = 30;
  private isMale: boolean = true;

  /**
   * 设置用户档案，用于构造连接后的用户包
   */
  setUserProfile(heightCm: number, age: number, isMale: boolean, userId: number): void {
    this.heightCm = heightCm;
    this.age = age;
    this.isMale = isMale;
    this.userId = userId;
  }

  matchDevice(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): boolean {
    const name = (deviceName || '').toUpperCase();
    return name.indexOf('YUNMAI-') === 0;
  }

  onServicesDiscovered(services: ServiceRef[]): string[] {
    const list: string[] = [];
    for (const svc of services) {
      if (svc.serviceUuid.toLowerCase().indexOf('ffe0') >= 0 ||
        svc.serviceUuid.toLowerCase() === SVC_MEAS) {
        for (const ch of svc.characteristics) {
          if (ch.characteristicUuid.toLowerCase().indexOf('ffe4') >= 0) {
            list.push(ch.characteristicUuid);
          }
        }
      }
    }
    return list;
  }

  onConnected(services: ServiceRef[]): Array<PendingWrite> {
    const writes: Array<PendingWrite> = [];
    // 找到命令特征的真实 UUID（不同固件可能略有差异）
    let cmdService = SVC_CMD;
    let cmdChar = CHR_CMD;
    for (const svc of services) {
      if (svc.serviceUuid.toLowerCase().indexOf('ffe5') >= 0) {
        cmdService = svc.serviceUuid;
        for (const ch of svc.characteristics) {
          if (ch.characteristicUuid.toLowerCase().indexOf('ffe9') >= 0) {
            cmdChar = ch.characteristicUuid;
          }
        }
      }
    }
    const userWrite: PendingWrite = {
      serviceUuid: cmdService,
      characteristicUuid: cmdChar,
      data: this.buildUserPacket()
    };
    const timeWrite: PendingWrite = {
      serviceUuid: cmdService,
      characteristicUuid: cmdChar,
      data: this.buildSetTimePacket()
    };
    const startWrite: PendingWrite = {
      serviceUuid: cmdService,
      characteristicUuid: cmdChar,
      data: new Uint8Array([0x0D, 0x05, 0x22, 0x00, 0x16])
    };
    writes.push(userWrite);
    writes.push(timeWrite);
    writes.push(startWrite);
    return writes;
  }

  /**
   * 用户档案包：0D 12 10 01 00 00 [uid_hi uid_lo] [height] [sex] [age] 55 5A 00 00 [unit] [activity] [xor]
   */
  private buildUserPacket(): Uint8Array {
    const p = new Uint8Array(18);
    p[0] = 0x0D;
    p[1] = 0x12;
    p[2] = 0x10; // SET_USER
    p[3] = 0x01;
    p[4] = 0x00;
    p[5] = 0x00;
    p[6] = (this.userId >> 8) & 0xFF;
    p[7] = this.userId & 0xFF;
    p[8] = Math.min(255, Math.max(0, Math.round(this.heightCm))) & 0xFF;
    p[9] = this.isMale ? 0x01 : 0x02;
    p[10] = Math.min(255, Math.max(0, this.age)) & 0xFF;
    p[11] = 0x55;
    p[12] = 0x5A;
    p[13] = 0x00;
    p[14] = 0x00;
    p[15] = 0x01; // 单位：kg
    p[16] = 0x00; // 活动量
    p[17] = xorChecksum(p, 1, 17);
    return p;
  }

  /**
   * 时间同步包：0D 0D 11 [unix_time_be(4)] 00 00 00 00 00 [xor]
   */
  private buildSetTimePacket(): Uint8Array {
    const p = new Uint8Array(13);
    const t = Math.floor(Date.now() / 1000) >>> 0;
    p[0] = 0x0D;
    p[1] = 0x0D;
    p[2] = 0x11; // SET_TIME
    p[3] = (t >>> 24) & 0xFF;
    p[4] = (t >>> 16) & 0xFF;
    p[5] = (t >>> 8) & 0xFF;
    p[6] = t & 0xFF;
    p[12] = xorChecksum(p, 1, 12);
    return p;
  }

  onNotification(characteristicUuid: string, data: Uint8Array): WeightReading | null {
    const uuid = characteristicUuid.toLowerCase();
    if (uuid.indexOf('ffe4') < 0) {
      return null;
    }
    if (data.length < 18 || data[3] !== 0x02) {
      return null;
    }

    const tsSec = readUint32BE(data, 5);
    let timestamp = tsSec * 1000;
    // 1980-01-01 之前的时间戳不可信，回退到系统时间
    if (timestamp < 315532800000 || timestamp > Date.now() + 7 * 24 * 3600 * 1000) {
      timestamp = Date.now();
    }

    const weightKg = readUint16BE(data, 13) / 100.0;
    if (weightKg <= 0 || weightKg > 300) {
      return null;
    }

    const reading: WeightReading = {
      weightKg: weightKg,
      state: ScaleState.STABLE,
      weightType: WeightType.NET,
      timestamp: timestamp,
      rawUnit: WeightUnit.KG,
      rawValue: weightKg
    };

    // Mini 型号在偏移 15 上报阻抗
    if (data.length >= 17) {
      const imp = readUint16BE(data, 15);
      if (imp > 0 && imp < 10000) {
        reading.impedance = imp;
      }
    }
    return reading;
  }
}
