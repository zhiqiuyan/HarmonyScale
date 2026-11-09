/**
 * 本地数据存储服务
 *
 * 使用 @kit.ArkData 的 preferences（KV 持久化）保存：
 * - 用户档案（身高/年龄/性别/目标体重/展示单位）
 * - 历史称重记录（JSON 数组）
 * - 最近连接的设备 MAC，便于下次自动重连
 *
 * 所有数据仅存本地，不联网、不上传，符合健康数据的隐私要求。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BmiStandardChoice, Gender, UserProfile, WeightRecord, WeightUnit } from '../model/ScaleModels';

const DOMAIN: number = 0x0000;
const TAG: string = 'ScaleStore';
const STORE_NAME: string = 'harmony_scale_store';

const KEY_PROFILE: string = 'user_profile';
const KEY_RECORDS: string = 'weight_records';
const KEY_LAST_DEVICE: string = 'last_device_id';
/** 主题色索引：保存用户从「中国式传统颜色」中选择的配色，默认 0（黛绿） */
const KEY_THEME_COLOR: string = 'theme_color_index';

/** 默认用户档案 */
export function defaultUserProfile(): UserProfile {
  return {
    heightCm: 170,
    age: 30,
    gender: Gender.MALE,
    targetWeightKg: 65,
    displayUnit: WeightUnit.KG,
    bmiStandard: BmiStandardChoice.CHINA,
    nickname: '',
    avatarUri: ''
  };
}

export class ScaleDataStore {
  private store: preferences.Preferences | null = null;

  /**
   * 初始化存储
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, STORE_NAME);
      hilog.info(DOMAIN, TAG, 'preferences initialized');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 读取用户档案
   */
  async loadProfile(): Promise<UserProfile> {
    if (!this.store) {
      return defaultUserProfile();
    }
    try {
      const raw = await this.store.get(KEY_PROFILE, '') as string;
      if (!raw) {
        return defaultUserProfile();
      }
      const parsed: UserProfile = JSON.parse(raw) as UserProfile;
      // 校验字段，避免脏数据导致界面异常
      const def = defaultUserProfile();
      return {
        heightCm: this.clamp(parsed.heightCm, 50, 250, def.heightCm),
        age: this.clamp(parsed.age, 1, 120, def.age),
        gender: parsed.gender === Gender.FEMALE ? Gender.FEMALE : Gender.MALE,
        targetWeightKg: this.clamp(parsed.targetWeightKg, 20, 300, def.targetWeightKg),
        displayUnit: parsed.displayUnit === WeightUnit.LB ? WeightUnit.LB :
          (parsed.displayUnit === WeightUnit.ST ? WeightUnit.ST : WeightUnit.KG),
        // 兼容旧版本存档：缺失字段一律回落默认值
        bmiStandard: parsed.bmiStandard === BmiStandardChoice.WHO ?
          BmiStandardChoice.WHO : BmiStandardChoice.CHINA,
        nickname: typeof parsed.nickname === 'string' ? parsed.nickname.slice(0, 20) : '',
        avatarUri: typeof parsed.avatarUri === 'string' ? parsed.avatarUri.slice(0, 256) : ''
      };
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'loadProfile failed: %{public}s', JSON.stringify(err));
      return defaultUserProfile();
    }
  }

  /** 存储是否可用（初始化失败时写入会静默丢失，必须由调用方感知） */
  isReady(): boolean {
    return this.store !== null;
  }

  /**
   * 保存用户档案。返回是否真正落盘，禁止静默失败。
   */
  async saveProfile(profile: UserProfile): Promise<boolean> {
    if (!this.store) {
      hilog.error(DOMAIN, TAG, 'saveProfile aborted: preferences not initialized');
      return false;
    }
    try {
      await this.store.put(KEY_PROFILE, JSON.stringify(profile));
      await this.store.flush();
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'saveProfile failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /**
   * 读取全部历史记录（按时间倒序）
   */
  async loadRecords(): Promise<WeightRecord[]> {
    if (!this.store) {
      return [];
    }
    try {
      const raw = await this.store.get(KEY_RECORDS, '[]') as string;
      if (!raw) {
        return [];
      }
      const list = JSON.parse(raw) as WeightRecord[];
      if (!Array.isArray(list)) {
        return [];
      }
      list.sort((a: WeightRecord, b: WeightRecord) => b.timestamp - a.timestamp);
      return list;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'loadRecords failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  /**
   * 追加一条称重记录。
   * 同一分钟内重复读数视为同一次称重，只更新不新增。
   */
  async addRecord(record: WeightRecord): Promise<WeightRecord[]> {
    const list = await this.loadRecords();
    const ONE_MINUTE = 60 * 1000;
    const duplicateIdx = list.findIndex((r: WeightRecord) =>
      Math.abs(r.timestamp - record.timestamp) < ONE_MINUTE && Math.abs(r.weightKg - record.weightKg) < 0.05);
    if (duplicateIdx >= 0) {
      list[duplicateIdx] = record;
    } else {
      list.unshift(record);
    }
    // 最多保留 2000 条，避免无限增长
    const trimmed = list.slice(0, 2000);
    await this.saveRecords(trimmed);
    return trimmed;
  }

  /**
   * 保存全部记录。返回是否真正落盘。
   */
  async saveRecords(list: WeightRecord[]): Promise<boolean> {
    if (!this.store) {
      hilog.error(DOMAIN, TAG, 'saveRecords aborted: preferences not initialized');
      return false;
    }
    try {
      await this.store.put(KEY_RECORDS, JSON.stringify(list));
      await this.store.flush();
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'saveRecords failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /**
   * 删除单条记录
   */
  async deleteRecord(id: number): Promise<WeightRecord[]> {
    const list = await this.loadRecords();
    const next = list.filter((r: WeightRecord) => r.id !== id);
    await this.saveRecords(next);
    return next;
  }

  /**
   * 清空全部记录
   */
  async clearRecords(): Promise<void> {
    await this.saveRecords([]);
  }

  /**
   * 读取上次连接的设备地址
   */
  async loadLastDevice(): Promise<string> {
    if (!this.store) {
      return '';
    }
    try {
      return await this.store.get(KEY_LAST_DEVICE, '') as string;
    } catch (err) {
      return '';
    }
  }

  /**
   * 保存上次连接的设备地址
   */
  async saveLastDevice(deviceId: string): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.put(KEY_LAST_DEVICE, deviceId);
      await this.store.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'saveLastDevice failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 读取主题色索引（默认 0）
   */
  async loadThemeColor(): Promise<number> {
    if (!this.store) {
      return 0;
    }
    try {
      return await this.store.get(KEY_THEME_COLOR, 0) as number;
    } catch (err) {
      return 0;
    }
  }

  /**
   * 保存主题色索引。返回是否真正落盘。
   */
  async saveThemeColor(index: number): Promise<boolean> {
    if (!this.store) {
      hilog.error(DOMAIN, TAG, 'saveThemeColor aborted: preferences not initialized');
      return false;
    }
    try {
      await this.store.put(KEY_THEME_COLOR, index);
      await this.store.flush();
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'saveThemeColor failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /**
   * 导出记录为 CSV 文本
   */
  exportCsv(records: WeightRecord[]): string {
    const header = 'timestamp,date,weight_kg,bmi,body_fat_percent,impedance,source';
    const lines: string[] = [header];
    for (const r of records) {
      const d = new Date(r.timestamp);
      const dateStr = `${d.getFullYear()}-${this.pad(d.getMonth() + 1)}-${this.pad(d.getDate())} ` +
        `${this.pad(d.getHours())}:${this.pad(d.getMinutes())}`;
      lines.push([
        r.timestamp,
        dateStr,
        r.weightKg.toFixed(2),
        r.bmi.toFixed(1),
        r.bodyFatPercent !== undefined ? r.bodyFatPercent.toFixed(1) : '',
        r.impedance !== undefined ? r.impedance.toString() : '',
        (r.source || '').replace(/,/g, ' ')
      ].join(','));
    }
    return lines.join('\n');
  }

  private clamp(v: number, min: number, max: number, fallback: number): number {
    return (isFinite(v) && v >= min && v <= max) ? v : fallback;
  }

  private pad(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }
}
