/**
 * 体重秤数据模型定义
 *
 * 设计要点：
 * 1. 所有协议适配器统一输出 WeightReading，屏蔽各家差异。
 * 2. 重量一律以 kg 为内部基准单位存储，展示时再按用户偏好换算。
 * 3. 时间戳统一为毫秒级 Unix 时间戳。
 */

/** 重量单位 */
export enum WeightUnit {
  /** 千克 */
  KG = 'kg',
  /** 磅 */
  LB = 'lb',
  /** 英石 */
  ST = 'st'
}

/** 秤的测量状态 */
export enum ScaleState {
  /** 读数稳定，可记录 */
  STABLE = 'stable',
  /** 读数未稳定（正在变化） */
  UNSTABLE = 'unstable',
  /** 超量程 */
  OVERLOAD = 'overload',
  /** 归零/无有效读数 */
  EMPTY = 'empty',
  /** 未知 */
  UNKNOWN = 'unknown'
}

/** 体重类型 */
export enum WeightType {
  /** 毛重 */
  GROSS = 'gross',
  /** 净重（扣皮重） */
  NET = 'net'
}

/**
 * 一次体重测量结果（统一输出模型）
 */
export interface WeightReading {
  /** 重量（千克为基准） */
  weightKg: number;
  /** 测量状态 */
  state: ScaleState;
  /** 体重类型 */
  weightType: WeightType;
  /** 测量时间戳（毫秒） */
  timestamp: number;
  /** 原始单位（设备上报单位） */
  rawUnit: WeightUnit;
  /** 原始数值（设备上报的原值） */
  rawValue: number;
  /** 阻抗（欧姆），部分体脂秤提供 */
  impedance?: number;
  /** 体脂率（%），部分秤直接提供 */
  bodyFatPercent?: number;
  /** 去脂体重（kg），部分秤直接提供 */
  leanBodyMassKg?: number;
  /** 骨骼肌量（kg），部分秤直接提供 */
  skeletalMuscleKg?: number;
  /** 身体水分（%），部分秤直接提供 */
  bodyWaterPercent?: number;
  /** 骨量（kg），部分秤直接提供 */
  boneMassKg?: number;
}

/** 扫描到的蓝牙设备信息 */
export interface ScannedDevice {
  /** 设备 MAC 地址 */
  deviceId: string;
  /** 设备名称（可能为空） */
  name: string;
  /** 信号强度 */
  rssi: number;
  /** 广播中携带的服务 UUID 列表 */
  serviceUuids: string[];
  /** 是否已被识别为体重秤 */
  isScaleCandidate: boolean;
  /** 命中的协议适配器名称（若有） */
  matchedAdapter?: string;
}

/** BMI 分级标准选择（持久化为字符串，避免与计算模块循环依赖） */
export enum BmiStandardChoice {
  /** 中国成人标准：18.5 / 24 / 28 */
  CHINA = 'china',
  /** WHO 国际标准：18.5 / 25 / 30 */
  WHO = 'who'
}

/** 用户档案 */
export interface UserProfile {
  /** 身高（厘米） */
  heightCm: number;
  /** 年龄 */
  age: number;
  /** 性别 */
  gender: Gender;
  /** 目标体重（千克） */
  targetWeightKg: number;
  /** 展示单位 */
  displayUnit: WeightUnit;
  /** BMI 分级标准 */
  bmiStandard: BmiStandardChoice;
  /** 用户昵称（仅本机展示） */
  nickname: string;
  /** 自定义头像 URI（沙箱内 file:// 路径；为空时使用默认占位头像） */
  avatarUri: string;
}

/** 性别 */
export enum Gender {
  MALE = 'male',
  FEMALE = 'female'
}

/** 历史记录条目 */
export interface WeightRecord {
  /** 记录唯一 id */
  id: number;
  /** 测量时间戳（毫秒） */
  timestamp: number;
  /** 体重（千克） */
  weightKg: number;
  /** BMI（体重/身高²） */
  bmi: number;
  /** 体脂率（%），无则 undefined */
  bodyFatPercent?: number;
  /** 阻抗（欧姆） */
  impedance?: number;
  /** 数据来源设备名 */
  source: string;
}
