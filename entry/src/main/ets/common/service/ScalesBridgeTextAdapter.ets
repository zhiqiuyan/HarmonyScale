/**
 * scales-bridge ASCII 文本协议适配器
 *
 * 移植自 https://github.com/xiangbohua/scales-bridge （Java，SPP/串口电子秤连接库）
 * 该库用「协议插件」把不同串口秤的字节流统一成 WeightDTO，本适配器把这套思路带到鸿蒙 BLE。
 *
 * 原库协议 A / B（18 字节定长帧，起始符 0x0A，结束符 0x0D）：
 *   偏移 0,1    状态：'ST' 稳定 / 'US' 不稳定 / 'OL' 超载
 *   偏移 3,4    重量类型：'GS' 毛重 / 'NT' 净重
 *   偏移 6..12  重量数值（7 字节 ASCII，右对齐/空格填充）
 *   偏移 14,15  单位：'KG' / 'LB'
 *
 * 原库协议 C（8 字节，结束符 '='）：
 *   ASCII 数值流，同样以 '=' 结尾
 *
 * 常见 BLE 透传模块（如 0xFFE0/0xFFE1、0xFFF0/0xFFF1、Nordic UART 0x6E400001）
 * 会把串口秤的字节流原样转发为 notify 数据，因此该适配器对串口秤同样有效。
 *
 * 实现说明：
 * - 内置字节流缓冲区，处理 notify 拆包/粘包（BLE 单包可能截断或合并多帧）。
 * - 除严格的定长帧偏移解析外，另提供正则兜底解析「数字+单位」文本，
 *   兼容厂商在 18 字节布局上的细微差异（原库 ProtocolC 的偏移实现即存在越界 bug）。
 */

import { ScaleState, WeightReading, WeightType, WeightUnit } from '../model/ScaleModels';
import { concatBytes, readAscii } from '../util/ByteUtils';
import { CharacteristicRef, ProtocolAdapter, ServiceRef } from './ProtocolAdapter';

/** BLE 透传特征常见 UUID 片段 */
const UART_UUID_HINTS: string[] = ['ffe1', 'fff1', '6e400003', '0000ff01', '2a9d'];

export class ScalesBridgeTextAdapter implements ProtocolAdapter {
  readonly id: string = 'scales-bridge-text';
  readonly displayName: string = 'scales-bridge 文本协议 (串口/透传电子秤)';

  /** 字节流缓冲，用于拆包粘包 */
  private buffer: Uint8Array = new Uint8Array(0);
  /** 上次读数，用于去重 */
  private lastWeightKg: number = -1;

  matchDevice(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): boolean {
    const name = (deviceName || '').toUpperCase();
    // 常见串口透传/电子秤命名
    const hints = ['SCALE', 'WEIGH', 'HC-', 'JDY', 'BT05', 'BLE-', 'SERIAL', 'UART', '电子秤'];
    for (const h of hints) {
      if (name.indexOf(h) >= 0) {
        return true;
      }
    }
    const lower = serviceUuids.map((u: string) => u.toLowerCase());
    return lower.some((u: string) => u.indexOf('ffe0') >= 0 || u.indexOf('fff0') >= 0 ||
      u.indexOf('6e400001') >= 0);
  }

  onServicesDiscovered(services: ServiceRef[]): string[] {
    const list: string[] = [];
    for (const svc of services) {
      const s = svc.serviceUuid.toLowerCase();
      if (s.indexOf('ffe0') >= 0 || s.indexOf('fff0') >= 0 ||
        s.indexOf('6e400001') >= 0 || s.indexOf('ff00') >= 0) {
        for (const ch of svc.characteristics) {
          const c = ch.characteristicUuid.toLowerCase();
          if (UART_UUID_HINTS.some((u: string) => c.indexOf(u) >= 0) && ch.notifyable) {
            list.push(ch.characteristicUuid);
          }
        }
      }
    }
    return list;
  }

  onNotification(characteristicUuid: string, data: Uint8Array): WeightReading | null {
    this.buffer = concatBytes(this.buffer, data);
    // 限制缓冲区长度，防止异常设备持续灌入无效数据导致内存增长
    if (this.buffer.length > 512) {
      this.buffer = this.buffer.slice(this.buffer.length - 256);
    }
    const reading = this.extractReading();
    if (!reading) {
      return null;
    }
    // 同值去重（原库 WeightDTO.isSame 的行为）
    if (Math.abs(reading.weightKg - this.lastWeightKg) < 0.0001) {
      return null;
    }
    this.lastWeightKg = reading.weightKg;
    return reading;
  }

  /**
   * 从缓冲区中提取一个完整读数
   */
  private extractReading(): WeightReading | null {
    const len = this.buffer.length;
    if (len === 0) {
      return null;
    }

    // 策略一：协议 C —— 以 '=' 结尾的 ASCII 数值
    for (let i = 0; i < len; i++) {
      if (this.buffer[i] === 0x3D) { // '='
        const segment = this.buffer.slice(0, i);
        const text = readAscii(segment, 0, segment.length);
        const r = this.parseLooseText(text);
        this.buffer = this.buffer.slice(i + 1);
        if (r) {
          return r;
        }
        return this.extractReading();
      }
    }

    // 策略二：协议 A/B —— 以 0x0A 起始、0x0D 结束的 18 字节帧
    let startIdx = -1;
    for (let i = 0; i < len; i++) {
      if (this.buffer[i] === 0x0A) {
        startIdx = i;
        break;
      }
    }
    if (startIdx >= 0) {
      const payloadStart = startIdx + 1;
      // 优先按结束符切帧
      for (let i = payloadStart; i < len; i++) {
        if (this.buffer[i] === 0x0D) {
          const segment = this.buffer.slice(payloadStart, i);
          this.buffer = this.buffer.slice(i + 1);
          const r = segment.length >= 16 ? this.parseFixedFrame(segment) : this.parseLooseText(readAscii(segment, 0, segment.length));
          return r;
        }
      }
      // 尚无结束符但已凑够 18 字节，按定长解析
      if (len - payloadStart >= 18) {
        const segment = this.buffer.slice(payloadStart, payloadStart + 18);
        this.buffer = this.buffer.slice(payloadStart + 18);
        return this.parseFixedFrame(segment);
      }
      // 丢弃起始符之前的噪声
      if (startIdx > 0) {
        this.buffer = this.buffer.slice(startIdx);
      }
      return null;
    }

    // 策略三：无起始符的纯文本（部分透传模块只发数值+换行）
    for (let i = 0; i < len; i++) {
      if (this.buffer[i] === 0x0D || this.buffer[i] === 0x0A) {
        const segment = this.buffer.slice(0, i);
        this.buffer = this.buffer.slice(i + 1);
        return this.parseLooseText(readAscii(segment, 0, segment.length));
      }
    }
    return null;
  }

  /**
   * 解析原库 A/B 协议的 18 字节定长帧
   */
  private parseFixedFrame(segment: Uint8Array): WeightReading | null {
    if (segment.length < 16) {
      return null;
    }
    const stateStr = readAscii(segment, 0, 2).toUpperCase();
    const typeStr = readAscii(segment, 3, 2).toUpperCase();
    const valueStr = readAscii(segment, 6, 7);
    const unitStr = readAscii(segment, 14, 2).toUpperCase();

    // 状态：US 不稳定丢弃，OL 超载
    if (stateStr === 'OL') {
      return null;
    }
    if (stateStr === 'US') {
      return null;
    }

    const value = parseFloat(valueStr);
    if (!isFinite(value) || value <= 0) {
      // 回退到宽松解析，兼容布局差异
      return this.parseLooseText(readAscii(segment, 0, segment.length));
    }

    const isLb = unitStr === 'LB';
    const weightKg = isLb ? value * 0.45359237 : value;
    if (weightKg <= 0 || weightKg > 500) {
      return null;
    }

    return {
      weightKg: weightKg,
      state: ScaleState.STABLE,
      weightType: typeStr === 'NT' ? WeightType.NET : WeightType.GROSS,
      timestamp: Date.now(),
      rawUnit: isLb ? WeightUnit.LB : WeightUnit.KG,
      rawValue: value
    };
  }

  /**
   * 宽松文本解析：从任意 ASCII 文本中提取「数值 + 单位」
   * 例：「  65.35 kg」「US,GS,  65.35,KG」「65.35=」
   */
  private parseLooseText(text: string): WeightReading | null {
    if (!text) {
      return null;
    }
    const cleaned = text.toUpperCase().replace(/,/g, ' ');
    // 忽略不稳定/超载帧
    if (cleaned.indexOf('US') >= 0 || cleaned.indexOf('OL') >= 0) {
      return null;
    }
    const m = cleaned.match(/(-?\d+(?:\.\d+)?)\s*(KG|LB|LBS|G)?/);
    if (!m) {
      return null;
    }
    const value = parseFloat(m[1]);
    if (!isFinite(value) || value <= 0) {
      return null;
    }
    const unitTag = m[2] ?? '';
    let weightKg: number;
    let unit: WeightUnit;
    if (unitTag === 'LB' || unitTag === 'LBS') {
      weightKg = value * 0.45359237;
      unit = WeightUnit.LB;
    } else if (unitTag === 'G') {
      weightKg = value / 1000.0;
      unit = WeightUnit.KG;
    } else {
      weightKg = value;
      unit = WeightUnit.KG;
    }
    if (weightKg <= 0 || weightKg > 500) {
      return null;
    }
    return {
      weightKg: weightKg,
      state: ScaleState.STABLE,
      weightType: WeightType.NET,
      timestamp: Date.now(),
      rawUnit: unit,
      rawValue: value
    };
  }

  onDisconnected(): void {
    this.buffer = new Uint8Array(0);
    this.lastWeightKg = -1;
  }
}
