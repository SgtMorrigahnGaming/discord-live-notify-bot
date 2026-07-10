const path = require('path');
const { createCanvas, loadImage, GlobalFonts } = require('@napi-rs/canvas');
const logger = require('./logger');

// Bundle our own font rather than relying on the OS having one installed — the Docker base
// image (node:22-slim) ships with no fonts at all, which would otherwise render blank text.
const FONT_DIR = path.resolve(__dirname, '../../node_modules/@fontsource/inter/files');
let fontsReady = false;
function ensureFonts() {
  if (fontsReady) return;
  try {
    GlobalFonts.registerFromPath(path.join(FONT_DIR, 'inter-latin-700-normal.woff2'), 'Inter-Bold');
    GlobalFonts.registerFromPath(path.join(FONT_DIR, 'inter-latin-600-normal.woff2'), 'Inter-Semibold');
    GlobalFonts.registerFromPath(path.join(FONT_DIR, 'inter-latin-400-normal.woff2'), 'Inter-Regular');
    fontsReady = true;
  } catch (err) {
    logger.error('Failed to register welcome card fonts:', err);
  }
}

function roundedRectPath(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/** Shrinks font size until the text fits within maxWidth, down to a minimum size. */
function fitFontSize(ctx, text, family, startSize, minSize, maxWidth) {
  let size = startSize;
  while (size > minSize) {
    ctx.font = `700 ${size}px ${family}`;
    if (ctx.measureText(text).width <= maxWidth) break;
    size -= 2;
  }
  return size;
}

async function generateWelcomeCard({ avatarUrl, username, guildName, memberCount }) {
  ensureFonts();

  const W = 900, H = 300;
  const canvas = createCanvas(W, H);
  const ctx = canvas.getContext('2d');

  // Card background with rounded corners
  roundedRectPath(ctx, 0, 0, W, H, 24);
  ctx.clip();

  const bgGrad = ctx.createLinearGradient(0, 0, W, H);
  bgGrad.addColorStop(0, '#14151b');
  bgGrad.addColorStop(1, '#2a1a4a');
  ctx.fillStyle = bgGrad;
  ctx.fillRect(0, 0, W, H);

  // Soft decorative glow, top-right — purely cosmetic, keeps it from feeling too flat/corporate
  const glow = ctx.createRadialGradient(W - 80, 40, 0, W - 80, 40, 220);
  glow.addColorStop(0, 'rgba(145, 70, 255, 0.35)');
  glow.addColorStop(1, 'rgba(145, 70, 255, 0)');
  ctx.fillStyle = glow;
  ctx.fillRect(0, 0, W, H);

  // Avatar
  const avatarSize = 176;
  const avatarX = 62;
  const avatarY = (H - avatarSize) / 2;

  let avatarImg = null;
  try {
    if (avatarUrl) {
      const res = await fetch(avatarUrl);
      if (res.ok) {
        const buf = Buffer.from(await res.arrayBuffer());
        avatarImg = await loadImage(buf);
      }
    }
  } catch (err) {
    logger.warn('Welcome card: failed to load avatar, using fallback:', err.message);
  }

  ctx.save();
  ctx.beginPath();
  ctx.arc(avatarX + avatarSize / 2, avatarY + avatarSize / 2, avatarSize / 2, 0, Math.PI * 2);
  ctx.closePath();
  ctx.clip();
  if (avatarImg) {
    ctx.drawImage(avatarImg, avatarX, avatarY, avatarSize, avatarSize);
  } else {
    ctx.fillStyle = '#5865f2';
    ctx.fillRect(avatarX, avatarY, avatarSize, avatarSize);
  }
  ctx.restore();

  // Ring around avatar
  ctx.beginPath();
  ctx.arc(avatarX + avatarSize / 2, avatarY + avatarSize / 2, avatarSize / 2 + 3, 0, Math.PI * 2);
  ctx.lineWidth = 5;
  ctx.strokeStyle = '#9146ff';
  ctx.stroke();

  // Text block
  const textX = avatarX + avatarSize + 44;
  const maxTextWidth = W - textX - 40;

  ctx.fillStyle = '#9146ff';
  ctx.font = '700 16px Inter-Semibold';
  ctx.textBaseline = 'alphabetic';
  ctx.fillText('W E L C O M E', textX, 108);

  const nameSize = fitFontSize(ctx, username, 'Inter-Bold', 46, 26, maxTextWidth);
  ctx.fillStyle = '#ffffff';
  ctx.font = `700 ${nameSize}px Inter-Bold`;
  ctx.fillText(username, textX, 108 + nameSize + 6);

  ctx.fillStyle = '#c3c5d0';
  ctx.font = '400 22px Inter-Regular';
  ctx.fillText(`to ${guildName}`, textX, 108 + nameSize + 44);

  if (memberCount) {
    ctx.fillStyle = '#8a8d9a';
    ctx.font = '400 16px Inter-Regular';
    ctx.fillText(`Member #${memberCount}`, textX, H - 34);
  }

  return canvas.toBuffer('image/png');
}

module.exports = { generateWelcomeCard };
