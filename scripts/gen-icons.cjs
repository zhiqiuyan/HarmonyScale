/**
 * 生成符合 HarmonyOS 应用图标规范的分层资源。
 *
 * 规范依据（design-guides / application-icon-0000001953444009 V17）：
 *  - 图标资源必须为分层资源（前景 + 背景双层）
 *  - 尺寸 1024*1024 px、正方形、PNG、无需圆角（系统自动生成遮罩）
 *  - 背景图不允许含透明像素
 *  - 主要内容居中，避免靠近四角被圆角裁切
 *  - 避免过于复杂的图层堆叠
 *
 * 项目约定（用户明确要求）：底板与前景均不使用渐变，采用单一纯色填充。
 * 官方指南建议底板「上浅下深」渐变以塑造光感，此处按用户偏好覆盖该建议，
 * 分层结构与纯白前景仍保留，靠挖空形成的层次保证轮廓辨识度。
 *
 * 输出：entry/src/main/resources/base/media/ 与 AppScope/resources/base/media/
 *   background.png  1024² 不透明纯色
 *   foreground.png  1024² 透明底纯白秤形主体
 *   app_icon.png    合成图（无透明），供 app.json5 使用
 *   startIcon.png   启动窗口图标（同合成图）
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const W = 1024;
const H = 1024;

/**
 * 可选纯色底板（RGB 三元组），无任何渐变或光感叠加。
 * 白色前景对比度：teal 5.5:1、indigo 9.8:1、coral 5.8:1，均高于 3:1 要求。
 * 切换方式：修改下方 PALETTE 一行后重新执行 `node scripts/gen-icons.cjs`。
 */
const SOLID_COLORS = {
  // 默认：青屿。低饱和青绿，与 UI 品牌色 #0D7377 完全一致。
  teal:   [13, 115, 119],
  // 备选一：靛夜。沉稳蓝紫，偏商务。
  indigo: [46, 58, 148],
  // 备选二：暮珊瑚。暖橙调，偏活力。
  coral:  [166, 72, 66]
};
const PALETTE = 'teal';

const OUT_DIRS = [
  path.join(__dirname, '..', 'entry', 'src', 'main', 'resources', 'base', 'media'),
  path.join(__dirname, '..', 'AppScope', 'resources', 'base', 'media')
];

// ---------------------------------------------------------------- PNG 编码
function crc32(buf) {
  let table = crc32.table;
  if (!table) {
    table = crc32.table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c;
    }
  }
  let crc = -1;
  for (let i = 0; i < buf.length; i++) {
    crc = table[(crc ^ buf[i]) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td), 0);
  return Buffer.concat([len, td, crc]);
}

function writePng(file, rgba, withAlpha) {
  const channels = withAlpha ? 4 : 3;
  const raw = Buffer.alloc((W * channels + 1) * H);
  let o = 0;
  for (let y = 0; y < H; y++) {
    raw[o++] = 0; // filter: none
    for (let x = 0; x < W; x++) {
      const s = (y * W + x) * 4;
      raw[o++] = rgba[s];
      raw[o++] = rgba[s + 1];
      raw[o++] = rgba[s + 2];
      if (withAlpha) {
        raw[o++] = rgba[s + 3];
      }
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(W, 0);
  ihdr.writeUInt32BE(H, 4);
  ihdr[8] = 8;                    // bit depth
  ihdr[9] = withAlpha ? 6 : 2;   // RGBA / RGB
  const png = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ]);
  fs.writeFileSync(file, png);
  return png.length;
}

// ---------------------------------------------------------------- SDF 工具
const clamp = (v, lo, hi) => v < lo ? lo : (v > hi ? hi : v);

function sdRoundRect(px, py, cx, cy, hw, hh, r) {
  const qx = Math.abs(px - cx) - (hw - r);
  const qy = Math.abs(py - cy) - (hh - r);
  const ax = Math.max(qx, 0);
  const ay = Math.max(qy, 0);
  return Math.hypot(ax, ay) + Math.min(Math.max(qx, qy), 0) - r;
}

function sdCircle(px, py, cx, cy, r) {
  return Math.hypot(px - cx, py - cy) - r;
}

function sdSegment(px, py, ax, ay, bx, by, w) {
  const vx = bx - ax;
  const vy = by - ay;
  const wx = px - ax;
  const wy = py - ay;
  const t = clamp((wx * vx + wy * vy) / (vx * vx + vy * vy), 0, 1);
  return Math.hypot(px - (ax + t * vx), py - (ay + t * vy)) - w;
}

/** SDF -> 覆盖率，1.1px 过渡带做抗锯齿 */
function cover(sd) {
  return clamp(0.5 - sd / 1.1, 0, 1);
}

/** 前景层 alpha over 一笔颜色 */
function paint(px, r, g, b, a) {
  const i = (px.y * W + px.x) * 4;
  const dstA = px.data[i + 3] / 255;
  const outA = a + dstA * (1 - a);
  if (outA <= 0) {
    px.data[i + 3] = 0;
    return;
  }
  px.data[i] = Math.round((r * a + px.data[i] * dstA * (1 - a)) / outA);
  px.data[i + 1] = Math.round((g * a + px.data[i + 1] * dstA * (1 - a)) / outA);
  px.data[i + 2] = Math.round((b * a + px.data[i + 2] * dstA * (1 - a)) / outA);
  px.data[i + 3] = Math.round(outA * 255);
}

/** 前景层挖空（alpha 减去一块），露出背景层 */
function carve(px, a) {
  const i = (px.y * W + px.x) * 4;
  px.data[i + 3] = Math.round((px.data[i + 3] / 255) * (1 - a) * 255);
}

// ---------------------------------------------------------------- 背景层
function buildBackground() {
  const data = Buffer.alloc(W * H * 4);
  const color = SOLID_COLORS[PALETTE];
  const r = color[0];
  const g = color[1];
  const b = color[2];
  // 单一纯色平铺：不写入 topGlow、radial 或任何纵向插值，全图 RGB 完全一致
  for (let i = 0; i < W * H; i++) {
    const o = i * 4;
    data[o] = r;
    data[o + 1] = g;
    data[o + 2] = b;
    data[o + 3] = 255; // 背景层绝不含透明像素
  }
  return data;
}

// ---------------------------------------------------------------- 前景层
function buildForeground() {
  const data = Buffer.alloc(W * H * 4);
  const px = { x: 0, y: 0, data };

  // 主体范围 x/y ∈ [256, 768]，占画布 50%，远离四角，系统圆角裁切不会截断
  const cx = 512;
  const cy = 528;

  for (let y = 0; y < H; y++) {
    px.y = y;
    for (let x = 0; x < W; x++) {
      px.x = x;
      const i = (y * W + x) * 4;
      data[i] = 255; data[i + 1] = 255; data[i + 2] = 255; data[i + 3] = 0;

      // 1) 秤体：纯白圆角方形，不使用上白下灰的光照渐变
      const shell = sdRoundRect(x, y, cx, cy, 252, 252, 118);
      const shellA = cover(shell);
      if (shellA > 0) {
        paint(px, 255, 255, 255, shellA);
      }

      // 2) 顶部读数屏：挖空圆角长条，透出纯色底板；与秤面保留 20px 呼吸间距
      const screen = sdRoundRect(x, y, cx, cy - 170, 112, 36, 36);
      const screenA = cover(screen);
      if (screenA > 0) {
        carve(px, screenA);
      }

      // 3) 秤面：挖空一个大圆，形成清晰的前后景层次
      const dial = sdCircle(x, y, cx, cy + 40, 150);
      const dialA = cover(dial);
      if (dialA > 0) {
        carve(px, dialA);
      }

      // 4) 指针：纯白圆头粗线段，指向左上（读数感）
      const needle = sdSegment(x, y, cx, cy + 40, cx - 80, cy + 40 - 90, 13);
      const needleA = cover(needle);
      if (needleA > 0) {
        paint(px, 255, 255, 255, needleA);
      }

      // 5) 中心轴点
      const hub = sdCircle(x, y, cx, cy + 40, 27);
      const hubA = cover(hub);
      if (hubA > 0) {
        paint(px, 255, 255, 255, hubA);
      }
    }
  }
  return data;
}

// ---------------------------------------------------------------- 合成图
function composite(bg, fg) {
  const out = Buffer.alloc(W * H * 4);
  for (let i = 0; i < W * H; i++) {
    const a = fg[i * 4 + 3] / 255;
    for (let c = 0; c < 3; c++) {
      out[i * 4 + c] = Math.round(fg[i * 4 + c] * a + bg[i * 4 + c] * (1 - a));
    }
    out[i * 4 + 3] = 255;
  }
  return out;
}

// ---------------------------------------------------------------- 主流程
const bg = buildBackground();
const fg = buildForeground();
const flat = composite(bg, fg);
const layeredImage = '{\n  "layered-image":\n  {\n    "background" : "$media:background",\n    "foreground" : "$media:foreground"\n  }\n}\n';

for (const dir of OUT_DIRS) {
  fs.mkdirSync(dir, { recursive: true });
  const sizes = {
    'background.png': writePng(path.join(dir, 'background.png'), bg, false),
    'foreground.png': writePng(path.join(dir, 'foreground.png'), fg, true),
    'app_icon.png': writePng(path.join(dir, 'app_icon.png'), flat, false),
    'startIcon.png': writePng(path.join(dir, 'startIcon.png'), flat, false)
  };
  fs.writeFileSync(path.join(dir, 'layered_image.json'), layeredImage, 'utf8');
  console.log(dir);
  for (const [name, size] of Object.entries(sizes)) {
    console.log(`  ${name.padEnd(18)} ${size} bytes`);
  }
  console.log('  layered_image.json');
}
