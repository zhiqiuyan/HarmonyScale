/**
 * 协议适配器抽象接口
 *
 * 各厂商体重秤的 GATT 布局与帧格式千差万别，这里用统一接口收敛差异：
 * - matchDevice：扫描阶段根据设备名/广播判断是否可能是本协议
 * - onServicesDiscovered：连接后发现服务，挑选需要订阅的特征并订阅
 * - onNotification：收到特征通知后交由协议解析
 * - onCharacteristicRead：主动读取特征值后的解析回调
 *
 * 新增厂商只需实现本接口并在 ProtocolRegistry 注册，无需改动连接与界面层。
 */

import { WeightReading } from '../model/ScaleModels';

/** 蓝牙特征描述（与鸿蒙 BLECharacteristic 对齐的子集） */
export interface CharacteristicRef {
  /** 所属服务 UUID */
  serviceUuid: string;
  /** 特征 UUID */
  characteristicUuid: string;
  /** 特征值 */
  value: Uint8Array;
  /** 是否可写 */
  writable: boolean;
  /** 是否支持通知 */
  notifyable: boolean;
  /** 是否支持指示 */
  indicatable: boolean;
}

/** 服务描述 */
export interface ServiceRef {
  serviceUuid: string;
  characteristics: CharacteristicRef[];
}

/** 连接后需要写入的特征与数据 */
export interface PendingWrite {
  serviceUuid: string;
  characteristicUuid: string;
  data: Uint8Array;
}

/**
 * 协议适配器
 */
export interface ProtocolAdapter {
  /** 适配器唯一标识 */
  readonly id: string;

  /** 展示名称，如「小米 Mi Body 2」 */
  readonly displayName: string;

  /**
   * 扫描阶段匹配。
   * @param deviceName 设备广播名
   * @param serviceUuids 广播携带的服务 UUID
   * @param manufacturerData 厂商数据（原始字节）
   * @param serviceData 服务数据
   */
  matchDevice(deviceName: string, serviceUuids: string[],
    manufacturerData: Uint8Array, serviceData: Uint8Array): boolean;

  /**
   * 服务发现完成后调用。
   * 返回需要订阅通知的特征 UUID 列表（characteristicUuid）。
   */
  onServicesDiscovered(services: ServiceRef[]): string[];

  /**
   * 收到通知数据。
   * @param characteristicUuid 特征 UUID
   * @param data 通知数据
   * @returns 解析出的测量结果；无有效读数返回 null
   */
  onNotification(characteristicUuid: string, data: Uint8Array): WeightReading | null;

  /**
   * 主动读取特征值后的解析回调（可选实现）。
   */
  onCharacteristicRead?(characteristicUuid: string, data: Uint8Array): WeightReading | null;

  /**
   * 连接建立后可选执行的初始化动作（如同步时间、写唤醒命令）。
   * 返回需要在连接后写入的特征及其数据。
   */
  onConnected?(services: ServiceRef[]): Array<PendingWrite>;

  /**
   * 广播型秤：直接从扫描广播中解析体重，无需建立 GATT 连接。
   * 国产体重秤（三诺、部分香山/乐心方案）大量采用此方式。
   * 返回 null 表示该广播无有效读数。
   */
  onAdvertisement?(deviceName: string, manufacturerData: Uint8Array,
    serviceData: Uint8Array): WeightReading | null;

  /**
   * 断开连接时清理内部状态。
   */
  onDisconnected?(): void;

  /**
   * 是否需要建立 GATT 连接。广播型秤返回 false。
   */
  requiresConnection?(): boolean;
}
