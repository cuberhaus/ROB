/**
 * HiDPI-aware canvas setup utility.
 * Applies devicePixelRatio scaling for sharp rendering on Retina displays.
 */

/**
 * Set up a canvas with HiDPI support.
 * @param {HTMLCanvasElement} canvas
 * @param {number} width - Logical width (CSS px)
 * @param {number} height - Logical height (CSS px)
 * @returns {CanvasRenderingContext2D}
 */
export function setupCanvas(canvas, width, height) {
  const dpr = window.devicePixelRatio || 1;
  canvas.width = width * dpr;
  canvas.height = height * dpr;
  canvas.style.width = width + 'px';
  canvas.style.height = height + 'px';
  const ctx = canvas.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0); // reset transform to clear fully
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return ctx;
}

/**
 * Create a 2D camera transform for panning/zooming.
 */
export function createCamera(cx = 0, cy = 0, scale = 1) {
  return { cx, cy, scale };
}

/**
 * Apply camera transform to context.
 */
export function applyCamera(ctx, cam, canvasW, canvasH) {
  const dpr = window.devicePixelRatio || 1;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.translate(canvasW / 2, canvasH / 2);
  ctx.scale(cam.scale, -cam.scale); // Flip y-axis
  ctx.translate(-cam.cx, -cam.cy);
}

/**
 * Draw an arrow (robot heading indicator).
 */
export function drawArrow(ctx, x, y, angle, size = 10) {
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(angle);
  ctx.beginPath();
  ctx.moveTo(size, 0);
  ctx.lineTo(-size * 0.6, size * 0.5);
  ctx.lineTo(-size * 0.3, 0);
  ctx.lineTo(-size * 0.6, -size * 0.5);
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}

/**
 * Draw a covariance ellipse.
 */
export function drawEllipse(ctx, cx, cy, rx, ry, angle, style = 'rgba(77,171,247,0.3)') {
  ctx.save();
  ctx.translate(cx, cy);
  ctx.rotate(angle);
  ctx.beginPath();
  ctx.ellipse(0, 0, Math.abs(rx), Math.abs(ry), 0, 0, Math.PI * 2);
  ctx.fillStyle = style;
  ctx.fill();
  ctx.strokeStyle = style.replace('0.3', '0.8');
  ctx.lineWidth = 1 / (ctx.getTransform().a || 1);
  ctx.stroke();
  ctx.restore();
}
