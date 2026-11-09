/**
 * Exingtech Y1 / VScale 及同类 20 字节大端帧体脂秤适配器
 *
 * 识别：广播名 "VScale" 或 GATT 服务 f433bd80-75b8-11e2-97d9-0002a5d5c51b
 *
 * 测量特征 1a2ea400-75b9-11e2-be05-0002a5d5c51b（notify）
 * 命令特征 29f11080-75b9-11e2-8bf6-0002a5d5c51b（write）
 *
 * 20 字节结果帧（全部为 uint16 大端，分辨率 0.1）：
 *   偏移 4   体重 (kg)
 *   偏移 6   体脂率 (%)
 *   偏移 8   水分 (%)
 *   偏移 10  骨量 (kg)
 *   偏移 12  肌肉量 (kg)
 *   偏移 14  内脏脂肪等级 (uint8)
 *   偏移 6 = 0xFF 时表示「仅体重帧」，需等待完整成分帧
 */

import { ScaleState, WeightReading, WeightType, WeightUnit } from '../model/ScaleModels';
import { readUint16BE } from '../util/ByteUtils';
import { ProtocolAdapter, ServiceRef } from './ProtocolAdapter';

const VSCALE_SERVICE = 'f433bd80-75b8-11e2-97d9-0002a5d5c51b';
const VSCALE_NOTIFY = '1a2ea400-75b9-11e2-be05-0002a5d5c51b';

export class VScaleAdapter implements ProtocolAdapter {
  readonly id: string = 'vscale';
  readonly displayName: string = 'VScale / Exingtech Y1 体脂秤';

  matchDevice(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): boolean {
    if ((deviceName || '').toLowerCase() === 'vscale') {
      return true;
    }
    return serviceUuids.some((u: string) => u.toLowerCase() === VSCALE_SERVICE);
  }

  onServicesDiscovered(services: ServiceRef[]): string[] {
    const list: string[] = [];
    for (const svc of services) {
      for (const ch of svc.characteristics) {
        if (ch.characteristicUuid.toLowerCase() === VSCALE_NOTIFY ||
          ch.characteristicUuid.toLowerCase().indexOf('1a2ea400') >= 0) {
          list.push(ch.characteristicUuid);
        }
      }
    }
    return list;
  }

  onNotification(characteristicUuid: string, data: Uint8Array): WeightReading | null {
    if (characteristicUuid.toLowerCase().indexOf('1a2ea400') < 0) {
      return null;
    }
    if (data.length !== 20) {
      return null;
    }
    // 0xFF 表示体脂数据尚未就绪，等待后续完整帧
    if (data[6] === 0xFF) {
      return null;
    }

    const weightKg = readUint16BE(data, 4) / 10.0;
    if (weightKg <= 0.5 || weightKg > 300) {
      return null;
    }

    const reading: WeightReading = {
      weightKg: weightKg,
      state: ScaleState.STABLE,
      weightType: WeightType.NET,
      timestamp: Date.now(),
      rawUnit: WeightUnit.KG,
      rawValue: weightKg
    };
    reading.bodyFatPercent = readUint16BE(data, 6) / 10.0;
    reading.bodyWaterPercent = readUint16BE(data, 8) / 10.0;
    reading.boneMassKg = readUint16BE(data, 10) / 10.0;
    reading.skeletalMuscleKg = readUint16BE(data, 12) / 10.0;
    return reading;
  }
}
