/**
 * Extended Kalman Filter for 2D mobile robot localization.
 * State: [x, y, theta]
 * Observation: landmark ranges
 */

/**
 * EKF state container.
 */
export function createEKF(x0 = 0, y0 = 0, theta0 = 0) {
  return {
    // State mean
    x: [x0, y0, theta0],
    // Covariance (3x3 as flat array, row-major)
    P: [0.01, 0, 0, 0, 0.01, 0, 0, 0, 0.01],
    // Process noise
    Q: [2.0, 0, 0, 0, 2.0, 0, 0, 0, 0.02],
    // Measurement noise (range variance)
    R_range: 400,
  };
}

/**
 * EKF predict step using odometry.
 * @param {object} ekf - EKF state
 * @param {number} dL - Left wheel delta (mm)
 * @param {number} dR - Right wheel delta (mm)
 * @param {number} W - Wheelbase (mm)
 */
export function ekfPredict(ekf, dL, dR, W = 520) {
  const [x, y, theta] = ekf.x;
  const dTheta = (dR - dL) / W;
  const dist = (dR + dL) / 2;
  const midTheta = theta + dTheta / 2;
  const newTheta = theta + dTheta;
  const dx = dist * Math.cos(midTheta);
  const dy = dist * Math.sin(midTheta);

  // Update state
  ekf.x = [x + dx, y + dy, newTheta];

  // Jacobian F = df/dx
  const F = [
    1, 0, -dist * Math.sin(midTheta),
    0, 1, dist * Math.cos(midTheta),
    0, 0, 1,
  ];

  // P = F * P * F^T + Q
  ekf.P = mat3Add(mat3MultABAt(F, ekf.P), ekf.Q);
}

/**
 * EKF update with a range measurement to a known landmark.
 * @param {object} ekf - EKF state
 * @param {number} measuredRange - Measured distance to landmark (mm)
 * @param {number} lx - Landmark x (mm)
 * @param {number} ly - Landmark y (mm)
 */
export function ekfUpdate(ekf, measuredRange, lx, ly) {
  const [x, y] = ekf.x;
  const dx = lx - x;
  const dy = ly - y;
  const predictedRange = Math.sqrt(dx * dx + dy * dy);

  if (predictedRange < 1e-6) return; // Too close, skip

  // Jacobian H = dh/dx
  const H = [-dx / predictedRange, -dy / predictedRange, 0];

  // Innovation
  const innovation = measuredRange - predictedRange;

  // S = H * P * H^T + R
  const S = vecMat3Vec(H, ekf.P) + ekf.R_range;

  // Kalman gain K = P * H^T / S
  const PHt = mat3Vec(ekf.P, H);
  const K = PHt.map((v) => v / S);

  // Update state
  ekf.x = ekf.x.map((xi, i) => xi + K[i] * innovation);

  // Update covariance using Joseph form for stability: P = (I-KH)P(I-KH)' + KRK'
  const KH = [
    K[0]*H[0], K[0]*H[1], K[0]*H[2],
    K[1]*H[0], K[1]*H[1], K[1]*H[2],
    K[2]*H[0], K[2]*H[1], K[2]*H[2],
  ];
  const IKH = [
    1-KH[0], -KH[1], -KH[2],
    -KH[3], 1-KH[4], -KH[5],
    -KH[6], -KH[7], 1-KH[8],
  ];
  const IKH_P_IKHt = mat3MultABAt(IKH, ekf.P);
  const KRKt = [
    K[0]*ekf.R_range*K[0], K[0]*ekf.R_range*K[1], K[0]*ekf.R_range*K[2],
    K[1]*ekf.R_range*K[0], K[1]*ekf.R_range*K[1], K[1]*ekf.R_range*K[2],
    K[2]*ekf.R_range*K[0], K[2]*ekf.R_range*K[1], K[2]*ekf.R_range*K[2],
  ];
  ekf.P = mat3Add(IKH_P_IKHt, KRKt);

  // Force symmetry to prevent numerical divergence
  ekf.P[1] = ekf.P[3] = (ekf.P[1] + ekf.P[3]) / 2;
  ekf.P[2] = ekf.P[6] = (ekf.P[2] + ekf.P[6]) / 2;
  ekf.P[5] = ekf.P[7] = (ekf.P[5] + ekf.P[7]) / 2;
}

/**
 * Get covariance ellipse parameters for visualization.
 * @returns {{ cx: number, cy: number, rx: number, ry: number, angle: number }}
 */
export function getCovarianceEllipse(ekf, nSigma = 2) {
  const P = ekf.P;
  // Extract 2x2 position covariance
  const a = P[0], b = P[1], d = P[4];
  const trace = a + d;
  const det = a * d - b * b;
  const disc = Math.sqrt(Math.max(0, trace * trace / 4 - det));
  const lambda1 = trace / 2 + disc;
  const lambda2 = trace / 2 - disc;
  const angle = Math.atan2(lambda1 - a, b) || 0;

  return {
    cx: ekf.x[0],
    cy: ekf.x[1],
    rx: nSigma * Math.sqrt(Math.max(0, lambda1)),
    ry: nSigma * Math.sqrt(Math.max(0, lambda2)),
    angle,
  };
}

// --- 3x3 matrix helpers (row-major flat arrays) ---

function mat3Mult(A, B) {
  const r = new Array(9).fill(0);
  for (let i = 0; i < 3; i++)
    for (let j = 0; j < 3; j++)
      for (let k = 0; k < 3; k++)
        r[i * 3 + j] += A[i * 3 + k] * B[k * 3 + j];
  return r;
}

function mat3Add(A, B) {
  return A.map((v, i) => v + B[i]);
}

/** Compute A * B * A^T */
function mat3MultABAt(A, B) {
  const AB = mat3Mult(A, B);
  const r = new Array(9).fill(0);
  for (let i = 0; i < 3; i++)
    for (let j = 0; j < 3; j++)
      for (let k = 0; k < 3; k++)
        r[i * 3 + j] += AB[i * 3 + k] * A[j * 3 + k]; // A^T[k][j] = A[j][k]
  return r;
}

/** H (1x3) * P (3x3) * H^T = scalar */
function vecMat3Vec(H, P) {
  let s = 0;
  for (let i = 0; i < 3; i++)
    for (let j = 0; j < 3; j++)
      s += H[i] * P[i * 3 + j] * H[j];
  return s;
}

/** P (3x3) * v (3x1) = 3x1 */
function mat3Vec(P, v) {
  const r = [0, 0, 0];
  for (let i = 0; i < 3; i++)
    for (let j = 0; j < 3; j++)
      r[i] += P[i * 3 + j] * v[j];
  return r;
}
