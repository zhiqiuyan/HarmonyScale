/**
 * BMI 与身体成分计算
 *
 * 参考依据：
 * - WHO 体重指数分类（BMI <18.5 消瘦、18.5–24.9 正常、25–29.9 超重、≥30 肥胖）
 * - 中国成人标准（WS/T 428–2013）：<18.5 消瘦、18.5–23.9 正常、24–27.9 超重、≥28 肥胖
 * - 体脂估算：基于 BMI + 年龄 + 性别（不含阻抗时的降级方案）
 * - 理想体重区间：BMI 18.5–23.9（中国标准）对应的体重范围
 */

import { Gender, UserProfile, WeightUnit } from '../model/ScaleModels';

/** BMI 分级标准 */
export enum BmiStandard {
  /** 世界卫生组织标准 */
  WHO = 'WHO',
  /** 中国成人标准 WS/T 428-2013 */
  CHINA = 'CHINA'
}

/** BMI 分级结果 */
export interface BmiClassification {
  /** BMI 数值 */
  bmi: number;
  /** 分级描述，如「偏瘦」「正常」「超重」「肥胖」 */
  label: string;
  /** 该分级下界的 BMI */
  lowerBound: number;
  /** 该分级上界的 BMI（开区间），Infinity 表示无上界 */
  upperBound: number;
  /** 分级色彩建议（十六进制） */
  color: string;
}

/** 体重区间 */
export interface WeightRange {
  min: number;
  max: number;
}

/** 身体成分估算结果 */
export interface BodyComposition {
  /** 体脂率（%） */
  bodyFatPercent: number;
  /** 骨骼肌量（kg） */
  skeletalMuscleKg: number;
  /** 去脂体重（kg） */
  leanBodyMassKg: number;
  /** 骨量（kg） */
  boneMassKg: number;
  /** 身体水分（%） */
  bodyWaterPercent: number;
  /** 内脏脂肪等级 */
  visceralFat: number;
}

/**
 * 计算 BMI
 * @param weightKg 体重（千克）
 * @param heightCm 身高（厘米）
 * @returns BMI 值；参数非法时返回 0
 */
export function calcBmi(weightKg: number, heightCm: number): number {
  if (!isFinite(weightKg) || !isFinite(heightCm) || weightKg <= 0 || heightCm <= 0) {
    return 0;
  }
  const heightM = heightCm / 100.0;
  return weightKg / (heightM * heightM);
}

/**
 * 对 BMI 进行分级
 * @param bmi BMI 值
 * @param standard 采用的分级标准
 */
export function classifyBmi(bmi: number, standard: BmiStandard = BmiStandard.CHINA): BmiClassification {
  if (!isFinite(bmi) || bmi <= 0) {
    return { bmi: 0, label: '未知', lowerBound: 0, upperBound: Infinity, color: '#8E8E93' };
  }
  if (standard === BmiStandard.WHO) {
    if (bmi < 18.5) {
      return { bmi, label: '偏瘦', lowerBound: 0, upperBound: 18.5, color: '#4A90D9' };
    } else if (bmi < 25) {
      return { bmi, label: '正常', lowerBound: 18.5, upperBound: 25, color: '#34C759' };
    } else if (bmi < 30) {
      return { bmi, label: '超重', lowerBound: 25, upperBound: 30, color: '#FF9F0A' };
    } else {
      return { bmi, label: '肥胖', lowerBound: 30, upperBound: Infinity, color: '#FF3B30' };
    }
  }
  // 中国标准
  if (bmi < 18.5) {
    return { bmi, label: '偏瘦', lowerBound: 0, upperBound: 18.5, color: '#4A90D9' };
  } else if (bmi < 24) {
    return { bmi, label: '正常', lowerBound: 18.5, upperBound: 24, color: '#34C759' };
  } else if (bmi < 28) {
    return { bmi, label: '超重', lowerBound: 24, upperBound: 28, color: '#FF9F0A' };
  } else {
    return { bmi, label: '肥胖', lowerBound: 28, upperBound: Infinity, color: '#FF3B30' };
  }
}

/**
 * 理想体重区间（基于中国标准 BMI 18.5–23.9）
 * @param heightCm 身高（厘米）
 */
export function idealWeightRangeKg(heightCm: number): WeightRange {
  const heightM = heightCm / 100.0;
  const range: WeightRange = {
    min: 18.5 * heightM * heightM,
    max: 23.9 * heightM * heightM
  };
  return range;
}

/**
 * 体脂率估算（无阻抗数据时的降级方案）
 *
 * 采用 Deurenberg 公式的 BMI 变体，并按年龄与性别做经验修正：
 *   体脂率(%) ≈ 1.20 × BMI + 0.23 × 年龄 − 10.8 × 性别系数 − 5.4
 * 其中性别系数：男 0（取 1.0），女 1（取 0）。
 *
 * 该式适用于总体人群，误差约 ±3–5%，属于估算值而非测量值。
 *
 * @param weightKg 体重（千克）
 * @param heightCm 身高（厘米）
 * @param age 年龄
 * @param gender 性别
 */
export function estimateBodyFatPercent(weightKg: number, heightCm: number, age: number, gender: Gender): number {
  const bmi = calcBmi(weightKg, heightCm);
  if (bmi <= 0) {
    return 0;
  }
  const sexFactor = gender === Gender.FEMALE ? 1 : 0;
  let fat = 1.20 * bmi + 0.23 * age - 10.8 * sexFactor - 5.4;
  fat = Math.max(fat, 5);
  fat = Math.min(fat, 65);
  return Math.round(fat * 10) / 10;
}

/**
 * 完整的身体成分估算
 */
export function estimateBodyComposition(weightKg: number, profile: UserProfile): BodyComposition {
  const bmi = calcBmi(weightKg, profile.heightCm);
  const fat = estimateBodyFatPercent(weightKg, profile.heightCm, profile.age, profile.gender);
  const leanMass = weightKg * (1 - fat / 100);

  // 骨骼肌量：以去脂体重为基数，按性别取经验比例
  const muscleRatio = profile.gender === Gender.MALE ? 0.52 : 0.46;
  const skeletalMuscle = leanMass * muscleRatio;

  // 骨量：约占体重的 13%（男性）/ 12%（女性）
  const boneMass = weightKg * (profile.gender === Gender.MALE ? 0.13 : 0.12);

  // 身体水分：瘦体重中水分占比约 72%，脂肪组织含水量约 10%
  const water = (leanMass * 0.72 + (weightKg - leanMass) * 0.10) / weightKg * 100;

  // 内脏脂肪等级：由 BMI 与腰围缺失时用经验映射
  let visceral = 1;
  if (bmi >= 30) {
    visceral = 12;
  } else if (bmi >= 28) {
    visceral = 9;
  } else if (bmi >= 24) {
    visceral = 6;
  } else if (bmi >= 20) {
    visceral = 4;
  } else {
    visceral = 2;
  }

  return {
    bodyFatPercent: fat,
    skeletalMuscleKg: Math.round(skeletalMuscle * 10) / 10,
    leanBodyMassKg: Math.round(leanMass * 10) / 10,
    boneMassKg: Math.round(boneMass * 10) / 10,
    bodyWaterPercent: Math.round(water * 10) / 10,
    visceralFat: visceral
  };
}

/**
 * 单位换算：千克 → 目标单位
 */
export function convertFromKg(kg: number, unit: WeightUnit): number {
  switch (unit) {
    case WeightUnit.LB:
      return kg * 2.2046226218;
    case WeightUnit.ST:
      return kg * 0.1574730704;
    default:
      return kg;
  }
}

/**
 * 单位换算：目标单位 → 千克
 */
export function convertToKg(value: number, unit: WeightUnit): number {
  switch (unit) {
    case WeightUnit.LB:
      return value / 2.2046226218;
    case WeightUnit.ST:
      return value / 0.1574730704;
    default:
      return value;
  }
}

/**
 * 单位显示符号
 */
export function unitSymbol(unit: WeightUnit): string {
  switch (unit) {
    case WeightUnit.LB:
      return 'lb';
    case WeightUnit.ST:
      return 'st';
    default:
      return 'kg';
  }
}

/**
 * 依据目标体重给出建议
 * @param currentKg 当前体重（千克）
 * @param targetKg 目标体重（千克）
 */
export function weightAdvice(currentKg: number, targetKg: number): string {
  if (!isFinite(currentKg) || !isFinite(targetKg) || currentKg <= 0) {
    return '暂无建议';
  }
  const diff = currentKg - targetKg;
  if (Math.abs(diff) < 0.3) {
    return '已达成目标体重，保持当前状态';
  }
  if (diff > 0) {
    return `距离目标还有 ${diff.toFixed(1)} kg，建议每周减重不超过 1 kg`;
  }
  return `距目标还差 ${Math.abs(diff).toFixed(1)} kg，建议均衡饮食与力量训练`;
}
