/**
 * 蓝牙扫描与连接服务
 *
 * 基于鸿蒙 @ohos.bluetooth.ble 模块封装：
 * - 扫描：ble.startBLEScan / ble.on('BLEDeviceFind')
 * - 连接：ble.createGattClientDevice → connect → getServices
 * - 订阅：gatt.setCharacteristicChangeNotification
 * - 取值：gatt.on('BLECharacteristicChange') / readCharacteristicValue
 *
 * 设计为「单连接」模式：体重秤同一时刻只需连接一台设备。
 */

import { ble, access } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { ScannedDevice, WeightReading } from '../model/ScaleModels';
import { CharacteristicRef, ProtocolAdapter, ServiceRef } from './ProtocolAdapter';

const DOMAIN: number = 0x0000;
const TAG: string = 'ScaleBt';

/** 蓝牙设备扫描结果（含广播原始数据） */
export interface RawScanDevice {
  deviceId: string;
  name: string;
  rssi: number;
  serviceUuids: string[];
  manufacturerData: Uint8Array;
  serviceData: Uint8Array;
}

/** 广播 AD 结构解析结果 */
interface AdvertisingInfo {
  serviceUuids: string[];
  manufacturerData: Uint8Array;
  serviceData: Uint8Array;
  deviceName: string;
}

/** 连接状态 */
export enum BtConnectionState {
  IDLE = 'idle',
  SCANNING = 'scanning',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  DISCONNECTED = 'disconnected',
  ERROR = 'error'
}

/**
 * 蓝牙秤连接管理器
 */
export class ScaleBluetoothService {
  /** 当前使用的协议适配器 */
  private adapter: ProtocolAdapter | null = null;
  /** GATT 客户端 */
  private gattClient: ble.GattClientDevice | null = null;
  /** 扫描结果去重表：deviceId -> RawScanDevice */
  private scannedMap: Map<string, RawScanDevice> = new Map();
  /** 订阅中的特征 UUID 集合 */
  private subscribed: Set<string> = new Set();
  /** 事件回调 */
  private onReadingCb: ((r: WeightReading) => void) | null = null;
  private onStateCb: ((s: BtConnectionState, msg?: string) => void) | null = null;
  private onDeviceFoundCb: ((d: RawScanDevice) => void) | null = null;
  /** 扫描过滤器（厂商专用服务 UUID），为空则扫描全部 */
  private scanFilterUuids: string[] = [];
  /** 广播型秤的适配器列表（无需连接，扫描即解析） */
  private broadcastAdapters: ProtocolAdapter[] = [];
  /** 当前连接设备名 */
  private currentDeviceName: string = '';

  /**
   * 读取系统蓝牙开关状态。
   * 返回值：'on' 可用（STATE_ON=2 / STATE_BLE_ON=5）、'off' 已关闭、
   * 'switching' 切换中、'unknown' 查询异常（权限或服务未就绪）。
   * 使用 access.getState()（API 10+），而非已废弃的 bluetooth.getState()。
   */
  getBluetoothState(): string {
    try {
      const state = access.getState();
      if (state === access.BluetoothState.STATE_ON ||
          state === access.BluetoothState.STATE_BLE_ON) {
        return 'on';
      }
      if (state === access.BluetoothState.STATE_OFF) {
        return 'off';
      }
      return 'switching';
    } catch (err) {
      return 'unknown';
    }
  }

  constructor() {
    // 注意：鸿蒙 BLEDeviceFind 回调参数是批量数组 Array<ScanResult>，不是单个结果
    ble.on('BLEDeviceFind', (results: Array<ble.ScanResult>) => {
      for (const result of results) {
        this.handleScanResult(result);
      }
    });
  }

  /**
   * 注册广播型协议适配器（扫描阶段直接解析体重，无需 GATT 连接）
   */
  setBroadcastAdapters(adapters: ProtocolAdapter[]): void {
    this.broadcastAdapters = adapters;
  }

  /**
   * 注册回调
   */
  setCallbacks(onReading: (r: WeightReading) => void,
    onState: (s: BtConnectionState, msg?: string) => void,
    onDeviceFound: (d: RawScanDevice) => void): void {
    this.onReadingCb = onReading;
    this.onStateCb = onState;
    this.onDeviceFoundCb = onDeviceFound;
  }

  /**
   * 申请蓝牙与位置权限
   * @param context 应用上下文
   */
  async requestPermissions(context: common.UIAbilityContext): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const result = await atManager.requestPermissionsFromUser(context, [
        'ohos.permission.ACCESS_BLUETOOTH',
        'ohos.permission.LOCATION'
      ]);
      return result.authResults.every((r: number) => r === 0);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'requestPermissions failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /**
   * 开始扫描
   * @param filterUuids 过滤的服务 UUID 列表；传空数组表示不过滤
   */
  startScan(filterUuids: string[] = []): void {
    this.scanFilterUuids = filterUuids;
    this.scannedMap.clear();
    try {
      const filters: ble.ScanFilter[] = [];
      if (filterUuids.length > 0) {
        for (const u of filterUuids) {
          filters.push({ serviceUuid: u } as ble.ScanFilter);
        }
      }
      ble.startBLEScan(filters, {
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        interval: 500
      });
      this.setState(BtConnectionState.SCANNING, '正在扫描附近体重秤...');
      hilog.info(DOMAIN, TAG, 'startBLEScan, filters=%{public}d', filters.length);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'startBLEScan failed: %{public}s', JSON.stringify(err));
      this.setState(BtConnectionState.ERROR, `扫描启动失败：${(err as BusinessError).message}`);
    }
  }

  /**
   * 停止扫描
   */
  stopScan(): void {
    try {
      ble.stopBLEScan();
      hilog.info(DOMAIN, TAG, 'stopBLEScan');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'stopBLEScan failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 处理扫描结果
   *
   * 不依赖 ScanResult.serviceUuids / manufacturerDataMap 等高版本字段（API 22+），
   * 而是直接解析 ScanResult.data 中的标准 BLE 广播 AD 结构，兼容到 API 10。
   */
  private handleScanResult(result: ble.ScanResult): void {
    const deviceId = result.deviceId;
    if (!deviceId) {
      return;
    }
    const adv = this.parseAdvertising(result.data);
    const name = result.deviceName ? result.deviceName : adv.deviceName;

    const raw: RawScanDevice = {
      deviceId: deviceId,
      name: name,
      rssi: result.rssi,
      serviceUuids: adv.serviceUuids,
      manufacturerData: adv.manufacturerData,
      serviceData: adv.serviceData
    };
    this.scannedMap.set(deviceId, raw);

    // 广播型秤：直接从广播数据解析读数
      for (const adapter of this.broadcastAdapters) {
        if (adapter.onAdvertisement) {
          const reading = adapter.onAdvertisement(name, raw.manufacturerData, raw.serviceData);
          if (reading && this.onReadingCb) {
            this.onReadingCb(reading);
          }
        }
      }

    if (this.onDeviceFoundCb) {
      this.onDeviceFoundCb(raw);
    }
  }

  /**
   * 解析标准 BLE 广播 AD 结构（Bluetooth Core Spec, AD Type）
   *
   * 每条 AD Structure = [长度 1B][类型 1B][数据 nB]
   *   0x02/0x03  16-bit Service UUID（不完整/完整列表）
   *   0x06/0x07  128-bit Service UUID（不完整/完整列表，小端）
   *   0x08/0x09  设备名（短名/完整名）
   *   0x16       Service Data（16-bit UUID）
   *   0xFF       Manufacturer Specific Data（含 2 字节 company id，小端）
   */
  private parseAdvertising(data: ArrayBuffer): AdvertisingInfo {
    const info: AdvertisingInfo = {
      serviceUuids: [],
      manufacturerData: new Uint8Array(0),
      serviceData: new Uint8Array(0),
      deviceName: ''
    };
    if (!data) {
      return info;
    }
    const bytes = new Uint8Array(data);
    let i = 0;
    while (i + 1 < bytes.length) {
      const len = bytes[i];
      if (len === 0) {
        break;
      }
      if (i + 1 + len > bytes.length) {
        break;
      }
      const type = bytes[i + 1];
      const payload = bytes.slice(i + 2, i + 1 + len);

      if (type === 0x02 || type === 0x03) {
        for (let j = 0; j + 1 < payload.length; j += 2) {
          const u16 = payload[j] | (payload[j + 1] << 8);
          info.serviceUuids.push(this.uuid16ToFull(u16));
        }
      } else if (type === 0x06 || type === 0x07) {
        for (let j = 0; j + 16 <= payload.length; j += 16) {
          info.serviceUuids.push(this.uuid128FromLe(payload, j));
        }
      } else if (type === 0x08 || type === 0x09) {
        if (info.deviceName.length === 0) {
          info.deviceName = this.readAsciiBytes(payload);
        }
      } else if (type === 0xFF) {
        if (info.manufacturerData.length === 0) {
          info.manufacturerData = payload;
        }
      } else if (type === 0x16 || type === 0x20 || type === 0x21) {
        if (info.serviceData.length === 0) {
          info.serviceData = payload;
        }
      }
      i += 1 + len;
    }
    return info;
  }

  /** 16 位 UUID 扩展为完整 128 位 Bluetooth Base UUID */
  private uuid16ToFull(u16: number): string {
    const h = (u16 & 0xFFFF).toString(16).toUpperCase().padStart(4, '0');
    return `0000${h}-0000-1000-8000-00805f9b34fb`;
  }

  /** 广播中的 128 位 UUID 是小端字节序，需反转为标准字符串 */
  private uuid128FromLe(bytes: Uint8Array, offset: number): string {
    const b: string[] = [];
    for (let i = 15; i >= 0; i--) {
      b.push(bytes[offset + i].toString(16).toUpperCase().padStart(2, '0'));
    }
    const h = b.join('');
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
  }

  private readAsciiBytes(bytes: Uint8Array): string {
    let s = '';
    for (let i = 0; i < bytes.length; i++) {
      if (bytes[i] >= 0x20 && bytes[i] < 0x7F) {
        s += String.fromCharCode(bytes[i]);
      }
    }
    return s.trim();
  }

  /**
   * 获取已扫描到的设备列表（按信号强度排序）
   */
  getScannedDevices(): RawScanDevice[] {
    const list: RawScanDevice[] = Array.from(this.scannedMap.values());
    list.sort((a: RawScanDevice, b: RawScanDevice) => b.rssi - a.rssi);
    return list;
  }

  /**
   * 连接设备并使用指定协议适配器
   * @param deviceId 设备 MAC
   * @param adapter 协议适配器
   */
  async connect(deviceId: string, adapter: ProtocolAdapter): Promise<boolean> {
    this.disconnect();
    this.adapter = adapter;
    this.currentDeviceName = '';
    this.setState(BtConnectionState.CONNECTING, '正在连接...');

    try {
      this.gattClient = ble.createGattClientDevice(deviceId);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'createGattClientDevice failed: %{public}s', JSON.stringify(err));
      this.setState(BtConnectionState.ERROR, `创建连接失败：${(err as BusinessError).message}`);
      return false;
    }

    // 注册连接状态与数据变化回调
    // 回调参数为 BLEConnectionChangeState，state 为 ProfileConnectionState 枚举：
    // 0=DISCONNECTED, 1=CONNECTING, 2=CONNECTED, 3=DISCONNECTING
    try {
      this.gattClient.on('BLEConnectionStateChange', (change: ble.BLEConnectionChangeState) => {
        hilog.info(DOMAIN, TAG, 'connectionStateChange: %{public}d', change.state);
        if (change.state === 2) {
          this.handleConnected();
        } else if (change.state === 0) {
          this.setState(BtConnectionState.DISCONNECTED, '连接已断开');
        }
      });

      this.gattClient.on('BLECharacteristicChange', (characteristic: ble.BLECharacteristic) => {
        this.handleCharacteristicChange(characteristic);
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'register BLE callbacks failed: %{public}s', JSON.stringify(err));
      this.setState(BtConnectionState.ERROR, '注册蓝牙回调失败');
      return false;
    }

    try {
      this.gattClient.connect();
      hilog.info(DOMAIN, TAG, 'connect invoked, deviceId=%{public}s', deviceId);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'connect failed: %{public}s', JSON.stringify(err));
      this.setState(BtConnectionState.ERROR, `连接失败：${(err as BusinessError).message}`);
      return false;
    }
  }

  /**
   * 连接成功后：发现服务、订阅通知、执行初始化
   */
  private async handleConnected(): Promise<void> {
    if (!this.gattClient || !this.adapter) {
      return;
    }
    try {
      const services = await this.gattClient.getServices();
      const serviceRefs: ServiceRef[] = services.map((svc: ble.GattService): ServiceRef => {
        return {
          serviceUuid: svc.serviceUuid,
          characteristics: svc.characteristics.map((ch: ble.BLECharacteristic): CharacteristicRef => {
            const props = ch.properties;
            return {
              serviceUuid: ch.serviceUuid,
              characteristicUuid: ch.characteristicUuid,
              value: new Uint8Array(ch.characteristicValue),
              writable: props ? (props.write === true || props.writeNoResponse === true) : false,
              notifyable: props ? (props.notify === true || props.indicate === true) : false,
              indicatable: props ? (props.indicate === true) : false
            };
          })
        };
      });

      // 订阅需要通知的特征
      const subscribeUuids = this.adapter.onServicesDiscovered(serviceRefs);
      for (const uuid of subscribeUuids) {
        await this.subscribeNotify(serviceRefs, uuid);
      }

      // 执行适配器自定义初始化（如小米历史同步、时间同步）
      if (this.adapter.onConnected) {
        const writes = this.adapter.onConnected(serviceRefs);
        for (const w of writes) {
          await this.writeValue(w.serviceUuid, w.characteristicUuid, w.data);
        }
      }

      this.setState(BtConnectionState.CONNECTED, '已连接，等待测量数据');
      hilog.info(DOMAIN, TAG, 'services discovered, subscribed=%{public}d', subscribeUuids.length);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'handleConnected failed: %{public}s', JSON.stringify(err));
      this.setState(BtConnectionState.ERROR, `服务发现失败：${(err as BusinessError).message}`);
    }
  }

  /**
   * 订阅通知
   */
  private async subscribeNotify(services: ServiceRef[], characteristicUuid: string): Promise<void> {
    if (!this.gattClient || this.subscribed.has(characteristicUuid.toLowerCase())) {
      return;
    }
    for (const svc of services) {
      for (const ch of svc.characteristics) {
        if (ch.characteristicUuid.toLowerCase() === characteristicUuid.toLowerCase()) {
          try {
            const characteristic: ble.BLECharacteristic = {
              serviceUuid: ch.serviceUuid,
              characteristicUuid: ch.characteristicUuid,
              characteristicValue: new ArrayBuffer(0),
              descriptors: []
            };
            await this.gattClient.setCharacteristicChangeNotification(characteristic, true);
            this.subscribed.add(ch.characteristicUuid.toLowerCase());
            hilog.info(DOMAIN, TAG, 'subscribed %{public}s', ch.characteristicUuid);
          } catch (err) {
            hilog.error(DOMAIN, TAG, 'setNotify failed: %{public}s', JSON.stringify(err));
          }
          return;
        }
      }
    }
  }

  /**
   * 特征值变化回调
   */
  private handleCharacteristicChange(characteristic: ble.BLECharacteristic): void {
    if (!this.adapter) {
      return;
    }
    const data = new Uint8Array(characteristic.characteristicValue);
    try {
      const reading = this.adapter.onNotification(characteristic.characteristicUuid, data);
      if (reading && this.onReadingCb) {
        this.onReadingCb(reading);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'parse failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 主动读取特征值
   */
  async readCharacteristic(serviceUuid: string, characteristicUuid: string): Promise<void> {
    if (!this.gattClient) {
      return;
    }
    try {
      const characteristic: ble.BLECharacteristic = {
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        characteristicValue: new ArrayBuffer(0),
        descriptors: []
      };
      const result = await this.gattClient.readCharacteristicValue(characteristic);
      if (this.adapter && result) {
        const reading = this.adapter.onCharacteristicRead
          ? this.adapter.onCharacteristicRead(characteristicUuid, new Uint8Array(result.characteristicValue))
          : null;
        if (reading && this.onReadingCb) {
          this.onReadingCb(reading);
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'readCharacteristic failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 写入特征值
   */
  async writeValue(serviceUuid: string, characteristicUuid: string, data: Uint8Array): Promise<boolean> {
    if (!this.gattClient) {
      return false;
    }
    try {
      const characteristic: ble.BLECharacteristic = {
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        characteristicValue: data.slice().buffer,
        descriptors: []
      };
      await this.gattClient.writeCharacteristicValue(characteristic, ble.GattWriteType.WRITE);
      hilog.info(DOMAIN, TAG, 'writeValue ok %{public}s', characteristicUuid);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'writeValue failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /**
   * 断开连接
   */
  disconnect(): void {
    this.subscribed.clear();
    if (this.adapter && this.adapter.onDisconnected) {
      this.adapter.onDisconnected();
    }
    if (this.gattClient) {
      try {
        this.gattClient.disconnect();
        this.gattClient.close();
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'disconnect failed: %{public}s', JSON.stringify(err));
      }
      this.gattClient = null;
    }
    this.adapter = null;
  }

  /**
   * 当前状态
   */
  getState(): BtConnectionState {
    if (this.gattClient) {
      return BtConnectionState.CONNECTED;
    }
    return BtConnectionState.IDLE;
  }

  private setState(s: BtConnectionState, msg?: string): void {
    if (this.onStateCb) {
      this.onStateCb(s, msg);
    }
  }
}
