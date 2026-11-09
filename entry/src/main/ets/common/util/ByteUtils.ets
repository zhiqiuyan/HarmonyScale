/**
 * 字节处理工具
 *
 * 鸿蒙 ArkTS 中 ArrayBuffer 与 Uint8Array 可互转，这里统一封装大���端/小端读取、
 * 十六进制打印与 CRC 校验，供各协议适配器复用。
 */

/** 将 ArrayBuffer 转为 Uint8Array（不复制） */
export function toUint8(buf: ArrayBuffer): Uint8Array {
  return new Uint8Array(buf);
}

/** 将 Uint8Array 拷贝为 ArrayBuffer */
export function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.slice().buffer;
}

/** 读取小端 uint16 */
export function readUint16LE(bytes: Uint8Array, offset: number): number {
  if (offset + 1 >= bytes.length) {
    return 0;
  }
  return bytes[offset] | (bytes[offset + 1] << 8);
}

/** 读取大端 uint16 */
export function readUint16BE(bytes: Uint8Array, offset: number): number {
  if (offset + 1 >= bytes.length) {
    return 0;
  }
  return (bytes[offset] << 8) | bytes[offset + 1];
}

/** 读取小端 uint24 */
export function readUint24LE(bytes: Uint8Array, offset: number): number {
  if (offset + 2 >= bytes.length) {
    return 0;
  }
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
}

/** 读取大端 uint24 */
export function readUint24BE(bytes: Uint8Array, offset: number): number {
  if (offset + 2 >= bytes.length) {
    return 0;
  }
  return (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];
}

/** 读取小端 uint32 */
export function readUint32LE(bytes: Uint8Array, offset: number): number {
  if (offset + 3 >= bytes.length) {
    return 0;
  }
  return (bytes[offset] | (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

/** 读取大端 uint32 */
export function readUint32BE(bytes: Uint8Array, offset: number): number {
  if (offset + 3 >= bytes.length) {
    return 0;
  }
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
}

/** 读取小端 int16 */
export function readInt16LE(bytes: Uint8Array, offset: number): number {
  const v = readUint16LE(bytes, offset);
  return v > 0x7FFF ? v - 0x10000 : v;
}

/** 读取大端 int16 */
export function readInt16BE(bytes: Uint8Array, offset: number): number {
  const v = readUint16BE(bytes, offset);
  return v > 0x7FFF ? v - 0x10000 : v;
}

/**
 * 从指定位置读取 ASCII 字符串
 * @param bytes 字节数组
 * @param offset 起始偏移
 * @param length 长度
 * @returns 去除首尾空白的字符串
 */
export function readAscii(bytes: Uint8Array, offset: number, length: number): string {
  if (offset >= bytes.length) {
    return '';
  }
  const end = Math.min(offset + length, bytes.length);
  let s = '';
  for (let i = offset; i < end; i++) {
    s += String.fromCharCode(bytes[i]);
  }
  return s.trim();
}

/**
 * 将字节数组转为十六进制字符串（用于日志）
 * @param bytes 字节数组
 * @param limit 最多显示的字节数
 */
export function toHexPreview(bytes: Uint8Array, limit: number = 24): string {
  const n = Math.min(bytes.length, limit);
  let s = '';
  for (let i = 0; i < n; i++) {
    const h = bytes[i].toString(16).toUpperCase().padStart(2, '0');
    s += (i > 0 ? ' ' : '') + h;
  }
  if (bytes.length > n) {
    s += ' …';
  }
  return s;
}

/**
 * CRC-16/CCITT 计算（小米体重秤历史帧使用）
 * @param bytes 数据
 * @param start 起始偏移
 * @param end 结束偏移（不含）
 */
export function crc16Ccitt(bytes: Uint8Array, start: number, end: number): number {
  let crc = 0;
  for (let i = start; i < end && i < bytes.length; i++) {
    crc ^= bytes[i] << 8;
    for (let bit = 0; bit < 8; bit++) {
      if (crc & 0x8000) {
        crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
      } else {
        crc = (crc << 1) & 0xFFFF;
      }
    }
  }
  return crc & 0xFFFF;
}

/**
 * 拼接两个 Uint8Array
 */
export function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/**
 * 判断两个字节数组是否相等
 */
export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}
