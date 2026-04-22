/**
 * Differential-drive odometry model.
 * Based on fib/ROB/entregas/Pose_Laser/p_OdometryLaser.py
 */

/**
 * Compute incremental pose from encoder deltas.
 * @param {number} dL - Left wheel distance (mm)
 * @param {number} dR - Right wheel distance (mm)
 * @param {number} theta - Current heading (rad)
 * @param {number} W - Wheelbase in mm (default 520)
 * @returns {{ dx: number, dy: number, dTheta: number }}
 */
export function odometryStep(dL, dR, theta, W = 520) {
  const dTheta = (dR - dL) / W;
  const dist = (dR + dL) / 2;
  // Use midpoint theta for better accuracy
  const midTheta = theta + dTheta / 2;
  const dx = Math.cos(midTheta) * dist;
  const dy = Math.sin(midTheta) * dist;
  return { dx, dy, dTheta };
}

/**
 * Build full trajectory from encoder arrays.
 * @param {number[][]} L_acu - Left encoder [timestamp, cumulative_mm]
 * @param {number[][]} R_acu - Right encoder [timestamp, cumulative_mm]
 * @param {number} W - Wheelbase in mm (default 520)
 * @param {number} x0 - Initial X position in mm
 * @param {number} y0 - Initial Y position in mm
 * @param {number} theta0 - Initial heading in rad
 * @returns {{ x: number[], y: number[], theta: number[], t: number[] }}
 */
export function buildTrajectory(L_acu, R_acu, W = 520, x0 = 0, y0 = 0, theta0 = 0) {
  const n = Math.min(L_acu.length, R_acu.length);
  const x = [x0], y = [y0], theta = [theta0], t = [0];

  for (let i = 1; i < n; i++) {
    const dL = L_acu[i][1] - L_acu[i - 1][1];
    const dR = R_acu[i][1] - R_acu[i - 1][1];
    const { dx, dy, dTheta } = odometryStep(dL, dR, theta[i - 1], W);
    x.push(x[i - 1] + dx);
    y.push(y[i - 1] + dy);
    theta.push(theta[i - 1] + dTheta);
    t.push(L_acu[i][0]);
  }

  return { x, y, theta, t };
}

/**
 * Convert polar laser scan to Cartesian points in robot frame.
 * @param {number[]} ranges - Ray distances (mm), -1 = invalid
 * @param {number} fov - Field of view (rad), default 240°
 * @returns {{ lx: number[], ly: number[] }}
 */
export function laserToCartesian(ranges, fov = (240 * Math.PI) / 180) {
  const n = ranges.length;
  const angleStep = fov / (n - 1);
  const startAngle = -fov / 2;
  const lx = [], ly = [];

  for (let i = 0; i < n; i++) {
    if (ranges[i] <= 0 || ranges[i] > 6000) continue;
    const angle = startAngle + i * angleStep;
    lx.push(ranges[i] * Math.cos(angle));
    ly.push(ranges[i] * Math.sin(angle));
  }
  return { lx, ly };
}

/**
 * Transform laser points from robot frame to world frame.
 */
export function transformPoints(lx, ly, rx, ry, rTheta) {
  const cos = Math.cos(rTheta);
  const sin = Math.sin(rTheta);
  const wx = [], wy = [];
  for (let i = 0; i < lx.length; i++) {
    wx.push(rx + cos * lx[i] - sin * ly[i]);
    wy.push(ry + sin * lx[i] + cos * ly[i]);
  }
  return { wx, wy };
}
