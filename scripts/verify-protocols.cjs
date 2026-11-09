#!/usr/bin/env node
/**
 * 协议解析验证脚本
 *
 * 目的：把真实的 ArkTS 协议适配器源码（.ets）用 TypeScript 转译为 CommonJS，
 * 在 Node 中喂入构造的样例字节帧，断言解析结果。这样验证的是交付代码本身，
 * 而不是另写一份"影子实现"。
 *
 * 用法：node scripts/verify-protocols.cjs
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const tsModule = require('C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript');

const ETS_ROOT = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
const moduleCache = new Map();

/** 把 .ets 源码转译为 CommonJS 并加载（支持相对 import） */
function loadEts(relPath) {
  const full = path.join(ETS_ROOT, relPath);
  const key = path.normalize(full);
  if (moduleCache.has(key)) {
    return moduleCache.get(key).exports;
  }

  const src = fs.readFileSync(full, 'utf8');
  const js = tsModule.transpileModule(src, {
    compilerOptions: {
      module: tsModule.ModuleKind.CommonJS,
      target: tsModule.ScriptTarget.ES2020
    },
    fileName: relPath
  }).outputText;

  const mod = { exports: {} };
  moduleCache.set(key, mod);
  const localRequire = (spec) => {
    if (!spec.startsWith('.')) {
      // 协议层不应依赖鸿蒙 Kit；若出现则说明分层被破坏
      throw new Error(`Unexpected Kit import in protocol layer: ${spec}`);
    }
    let target = path.normalize(path.join(path.dirname(full), spec));
    if (!target.endsWith('.ets') && !target.endsWith('.ts')) {
      target += '.ets';
    }
    return loadEts(path.relative(ETS_ROOT, target).replace(/\\/g, '/'));
  };
  const wrapper = new Function('exports', 'require', 'module', '__filename', '__dirname', js);
  wrapper(mod.exports, localRequire, mod, full, path.dirname(full));
  return mod.exports;
}

let passed = 0;
let failed = 0;

function assertClose(actual, expected, tol, label) {
  if (actual === null || actual === undefined || !isFinite(actual) || Math.abs(actual - expected) > tol) {
    console.error(`  FAIL  ${label}: 期望 ${expected}，实际 ${actual}`);
    failed++;
    return false;
  }
  console.log(`  PASS  ${label}: ${actual}`);
  passed++;
  return true;
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    console.error(`  FAIL  ${label}: 期望 ${expected}，实际 ${actual}`);
    failed++;
    return false;
  }
  console.log(`  PASS  ${label}: ${actual}`);
  passed++;
  return true;
}

function section(name) {
  console.log(`\n=== ${name} ===`);
}

const U8 = (arr) => new Uint8Array(arr);

// ---------------------------------------------------------------- 字节工具
section('字节工具 ByteUtils');
const byteUtils = loadEts('common/util/ByteUtils.ets');
assertEqual(byteUtils.readUint16LE(U8([0x0E, 0x33]), 0), 0x330E, '小端 uint16 (13070)');
assertEqual(byteUtils.readUint16BE(U8([0x19, 0x87]), 0), 0x1987, '大端 uint16 (6535)');
assertEqual(byteUtils.readUint32BE(U8([0x00, 0x00, 0x00, 0x64]), 0), 100, '大端 uint32');
assertEqual(byteUtils.readAscii(U8([0x20, 0x20, 0x36, 0x35, 0x2E, 0x33, 0x35]), 0, 7), '65.35', 'ASCII 去空白');
assertEqual(byteUtils.crc16Ccitt(U8([0x01, 0x02]), 0, 2) >= 0, true, 'CRC16 返回值有效');

// ---------------------------------------------------------------- BMI
section('BMI 计算');
const bmi = loadEts('common/util/BmiCalculator.ets');
const models = loadEts('common/model/ScaleModels.ets');
const bmiVal = bmi.calcBmi(65, 170);
assertClose(bmiVal, 22.491, 0.01, '65kg / 170cm → BMI');
assertEqual(bmi.classifyBmi(bmiVal, bmi.BmiStandard.CHINA).label, '正常', '中国标准 22.5 → 正常');
assertEqual(bmi.classifyBmi(25, bmi.BmiStandard.CHINA).label, '超重', '中国标准 25 → 超重');
assertEqual(bmi.classifyBmi(25, bmi.BmiStandard.WHO).label, '超重', 'WHO 标准 25 → 超重');
assertEqual(bmi.classifyBmi(24.9, bmi.BmiStandard.WHO).label, '正常', 'WHO 标准 24.9 → 正常');
assertClose(bmi.convertFromKg(65, models.WeightUnit.LB), 143.30, 0.02, 'kg → lb');
const range = bmi.idealWeightRangeKg(170);
assertClose(range.max, 69.07, 0.05, '170cm 理想体重上限');

// ---------------------------------------------------------------- 标准 BLE
section('标准 BLE Weight Scale (0x181D / 0x2A9D)');
const std = new (loadEts('common/service/StandardWeightProfileAdapter.ets').StandardWeightProfileAdapter)();
// flags=0, weight=13070 * 0.005 = 65.35 kg
let r = std.onNotification('00002a9d-0000-1000-8000-00805f9b34fb', U8([0x00, 0x0E, 0x33]));
assertClose(r && r.weightKg, 65.35, 0.001, 'SI 单位 0x330E → 65.35 kg');
// imperial: 150.00 lb → raw=15000=0x3A98
r = std.onNotification('00002a9d-0000-1000-8000-00805f9b34fb', U8([0x01, 0x98, 0x3A]));
assertClose(r && r.weightKg, 68.039, 0.01, 'Imperial 150.00 lb → 68.04 kg');
// 体成分帧：flags bit0 体脂、bit5 阻抗
std.onNotification('00002a9c-0000-1000-8000-00805f9b34fb', U8([0x21, 0x00, 0x01, 0xF4, 0x01]));
r = std.onNotification('00002a9d-0000-1000-8000-00805f9b34fb', U8([0x00, 0x0E, 0x33]));
assertClose(r && r.bodyFatPercent, 25.6, 0.01, '体脂率 0x0100 → 25.6%');
assertClose(r && r.impedance, 500, 0.001, '阻抗 0x01F4 → 500 Ω');

// ---------------------------------------------------------------- 小米
section('小米 Mi Scale v1/v2');
const MiScaleAdapter = loadEts('common/service/MiScaleAdapter.ets').MiScaleAdapter;
const mi = new MiScaleAdapter();
assertEqual(mi.matchDevice('MI SCALE2', [], U8([]), U8([])), true, '识别 MI SCALE2');
assertEqual(mi.matchDevice('MIBCS', [], U8([]), U8([])), true, '识别 MIBCS');
const miUuid = '00002a2f-0000-3512-2118-0009af100700';
// 13 字节实时帧：2026-11-08 12:30，稳定，kg，阻抗 500Ω，65.35kg
const mi13 = U8([0x00, 0x22, 0xEA, 0x07, 0x0B, 0x08, 0x0C, 0x1E, 0x00, 0xF4, 0x01, 0x0E, 0x33]);
r = mi.onNotification(miUuid, mi13);
assertClose(r && r.weightKg, 65.35, 0.001, 'v2 实时帧 13B → 65.35 kg');
assertClose(r && r.impedance, 500, 0.001, 'v2 实时帧阻抗 → 500 Ω');
// 10 字节历史帧：稳定、65.35kg、同时间
const mi10 = U8([0x20, 0x0E, 0x33, 0xEA, 0x07, 0x0B, 0x08, 0x0C, 0x1E, 0x00]);
r = mi.onNotification(miUuid, mi10);
assertClose(r && r.weightKg, 65.35, 0.001, 'v1 历史帧 10B → 65.35 kg');
// 不稳定帧应丢弃
assertEqual(mi.onNotification(miUuid, U8([0x00, 0x00, 0xEA, 0x07, 0x0B, 0x08, 0x0C, 0x1E, 0x00, 0x00, 0x00, 0x0E, 0x33])), null, '不稳定位 → 丢弃');

// ---------------------------------------------------------------- 云麦
section('云麦 Yunmai');
const YunmaiAdapter = loadEts('common/service/YunmaiAdapter.ets').YunmaiAdapter;
const yun = new YunmaiAdapter();
assertEqual(yun.matchDevice('YUNMAI-SIGNAL-XXX', [], U8([]), U8([])), true, '识别云麦设备名');
const yunFrame = U8(18);
yunFrame[3] = 0x02;                       // 测量完成
const ts = Math.floor(Date.now() / 1000);
yunFrame[5] = (ts >>> 24) & 0xFF;
yunFrame[6] = (ts >>> 16) & 0xFF;
yunFrame[7] = (ts >>> 8) & 0xFF;
yunFrame[8] = ts & 0xFF;
yunFrame[13] = 0x19; yunFrame[14] = 0x87; // 6535 / 100 = 65.35 kg
r = yun.onNotification('0000ffe4-0000-1000-8000-00805f9b34fb', yunFrame);
assertClose(r && r.weightKg, 65.35, 0.001, '云麦最终帧 → 65.35 kg');
assertEqual(yun.onNotification('0000ffe4-0000-1000-8000-00805f9b34fb', U8(18)), null, '非完成态帧 → 丢弃');

// ---------------------------------------------------------------- QN Scale
section('QN Scale (FITINDEX / Renpho / 香山)');
const QNScaleAdapter = loadEts('common/service/QNScaleAdapter.ets').QNScaleAdapter;
const qn = new QNScaleAdapter();
// 0x10 帧：weight 6535 (/100)，stable=1，R1=500
const qnFrame = U8([0x10, 0x0A, 0x01, 0x19, 0x87, 0x01, 0x01, 0xF4, 0x00, 0x00]);
r = qn.onNotification('0000ffe1-0000-1000-8000-00805f9b34fb', qnFrame);
assertClose(r && r.weightKg, 65.35, 0.001, 'QN 0x10 帧 → 65.35 kg');
assertClose(r && r.impedance, 500, 0.001, 'QN 阻抗 → 500 Ω');
assertEqual(qn.onNotification('0000ffe1-0000-1000-8000-00805f9b34fb', qnFrame), null, '同会话重复读数 → 丢弃');

// ---------------------------------------------------------------- VScale
section('VScale / Exingtech Y1');
const VScaleAdapter = loadEts('common/service/VScaleAdapter.ets').VScaleAdapter;
const vs = new VScaleAdapter();
const vsFrame = U8(20);
vsFrame[4] = 0x02; vsFrame[5] = 0x8D;  // 653 / 10 = 65.3 kg
vsFrame[6] = 0x00; vsFrame[7] = 0xFF;  // 体脂 25.5%
vsFrame[8] = 0x02; vsFrame[9] = 0x58;  // 水分 60.0%
r = vs.onNotification('1a2ea400-75b9-11e2-be05-0002a5d5c51b', vsFrame);
assertClose(r && r.weightKg, 65.3, 0.001, 'VScale 20B → 65.3 kg');
assertClose(r && r.bodyFatPercent, 25.5, 0.01, 'VScale 体脂 → 25.5%');

// ---------------------------------------------------------------- 广播型
section('广播型秤（三诺 / IFIT）');
const BroadcastScaleAdapter = loadEts('common/service/BroadcastScaleAdapter.ets').BroadcastScaleAdapter;
const bc = new BroadcastScaleAdapter();
const adv = U8(17);
adv[9] = 0x87; adv[10] = 0x19;  // 重量 6535（低字节在9、高字节在10）
let checksum = 0;
for (let i = 6; i <= 15; i++) { checksum ^= adv[i]; }
adv[16] = checksum & 0xFF;
let bcReading = null;
for (let i = 0; i < 9; i++) {
  bcReading = bc.onAdvertisement('Weight Scale', adv, U8([]));
}
assertClose(bcReading && bcReading.weightKg, 65.35, 0.001, '连续 9 次稳定 → 65.35 kg');
assertEqual(bc.onAdvertisement('Weight Scale', adv, U8([])), null, '同次称重不重复记录');

// ---------------------------------------------------------------- scales-bridge 文本
section('scales-bridge ASCII 文本协议');
const ScalesBridgeTextAdapter = loadEts('common/service/ScalesBridgeTextAdapter.ets').ScalesBridgeTextAdapter;
const sb = new ScalesBridgeTextAdapter();
const frameText = 'ST GS   65.35 KG  ';
const asciiFrame = U8(Array.from(frameText, (c) => c.charCodeAt(0)));
const full = U8([0x0A, ...asciiFrame, 0x0D]);
r = sb.onNotification('0000ffe1-0000-1000-8000-00805f9b34fb', full);
assertClose(r && r.weightKg, 65.35, 0.001, '18B 定长帧 → 65.35 kg');
assertEqual(r && r.weightType, models.WeightType.GROSS, '毛重标记 GS');
// 拆包：先发一半再发一半
const sb2 = new ScalesBridgeTextAdapter();
r = sb2.onNotification('0000ffe1-0000-1000-8000-00805f9b34fb', full.slice(0, 8));
assertEqual(r, null, '半包 → 暂不产出');
r = sb2.onNotification('0000ffe1-0000-1000-8000-00805f9b34fb', full.slice(8));
assertClose(r && r.weightKg, 65.35, 0.001, '粘包拼接后 → 65.35 kg');
// 协议 C：以 '=' 结尾
const sb3 = new ScalesBridgeTextAdapter();
r = sb3.onNotification('0000ffe1-0000-1000-8000-00805f9b34fb', U8(Array.from('65.35=', (c) => c.charCodeAt(0))));
assertClose(r && r.weightKg, 65.35, 0.001, '协议C "=" 终止 → 65.35 kg');

// ---------------------------------------------------------------- 注册表
section('协议注册表');
const registry = new (loadEts('common/service/ProtocolRegistry.ets').ProtocolRegistry)();
assertEqual(registry.list().length, 7, '已注册适配器数量');
assertEqual(registry.identify('MI SCALE2', [], U8([]), U8([])), 'mi-scale', '小米优先识别');
assertEqual(registry.identify('YUNMAI-ISSE', [], U8([]), U8([])), 'yunmai', '云麦识别');

// ---------------------------------------------------------------- 汇总
console.log(`\n${'='.repeat(52)}`);
console.log(`结果：${passed} 通过，${failed} 失败`);
console.log('='.repeat(52));
process.exit(failed > 0 ? 1 : 0);
