/**
 * Forward kinematics using DH parameters.
 * Supports Puma560, 3-link 3D, and custom DH tables.
 */

/**
 * DH parameter sets.
 * Each link: { theta, d, a, alpha } (in radians and meters)
 */
export const DH_PUMA560 = [
  { theta: 0, d: 0, a: 0, alpha: 0 },
  { theta: 0, d: 0, a: 0, alpha: -Math.PI / 2 },
  { theta: 0, d: 0.15005, a: 0.4318, alpha: 0 },
  { theta: 0, d: 0.4318, a: 0.0203, alpha: -Math.PI / 2 },
  { theta: 0, d: 0, a: 0, alpha: Math.PI / 2 },
  { theta: 0, d: 0, a: 0, alpha: -Math.PI / 2 },
];

export const DH_3LINK = [
  { theta: 0, d: 7, a: 0, alpha: Math.PI / 2 },
  { theta: 0, d: 0, a: 2, alpha: 0 },
  { theta: 0, d: 0, a: 1, alpha: 0 },
];

/** Named robot configurations */
export const ROBOT_CONFIGS = {
  puma560: { name: 'Puma 560', dh: DH_PUMA560, poses: {
    zero: [0, 0, 0, 0, 0, 0],
    ready: [0, -Math.PI/2, -Math.PI/2, 0, 0, 0],
    stretch: [0, 0, -Math.PI/2, Math.PI/2, 0, 0],
  }},
  threeLink: { name: '3-Link 3D', dh: DH_3LINK, poses: {
    zero: [0, 0, 0],
    bent: [0, Math.PI/4, -Math.PI/4],
  }},
};

/**
 * 4x4 identity matrix (flat array, column-major).
 */
function mat4Identity() {
  return [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
}

/**
 * Multiply two 4x4 matrices (column-major).
 */
function mat4Multiply(a, b) {
  const r = new Array(16).fill(0);
  for (let c = 0; c < 4; c++) {
    for (let row = 0; row < 4; row++) {
      let sum = 0;
      for (let k = 0; k < 4; k++) {
        sum += a[k * 4 + row] * b[c * 4 + k];
      }
      r[c * 4 + row] = sum;
    }
  }
  return r;
}

/**
 * Build DH transformation matrix for a single link (standard convention).
 * @param {number} theta - Joint angle (rad)
 * @param {number} d - Link offset
 * @param {number} a - Link length
 * @param {number} alpha - Link twist (rad)
 * @returns {number[]} 4x4 column-major matrix
 */
export function dhMatrix(theta, d, a, alpha) {
  const ct = Math.cos(theta), st = Math.sin(theta);
  const ca = Math.cos(alpha), sa = Math.sin(alpha);
  // Column-major storage
  return [
    ct,      st,      0,  0,
    -st*ca,  ct*ca,   sa, 0,
    st*sa,  -ct*sa,   ca, 0,
    a*ct,    a*st,    d,  1,
  ];
}

/**
 * Compute forward kinematics chain.
 * @param {Array<{theta:number, d:number, a:number, alpha:number}>} dh - DH parameters
 * @param {number[]} jointAngles - Joint angles (rad)
 * @returns {{ transforms: number[][], endEffector: number[] }}
 *   transforms[i] = cumulative 4x4 matrix up to link i, endEffector = final transform
 */
export function forwardKinematics(dh, jointAngles) {
  const transforms = [];
  let T = mat4Identity();

  for (let i = 0; i < dh.length; i++) {
    const q = jointAngles[i] ?? 0;
    const link = dh[i];
    const A = dhMatrix(link.theta + q, link.d, link.a, link.alpha);
    T = mat4Multiply(T, A);
    transforms.push([...T]);
  }

  return { transforms, endEffector: T };
}

/**
 * Extract position [x, y, z] from a 4x4 column-major matrix.
 */
export function getPosition(mat) {
  return [mat[12], mat[13], mat[14]];
}

/**
 * Get joint positions for rendering (series of [x,y,z]).
 */
export function getJointPositions(dh, jointAngles) {
  const { transforms } = forwardKinematics(dh, jointAngles);
  const positions = [[0, 0, 0]];
  for (const T of transforms) {
    positions.push(getPosition(T));
  }
  return positions;
}
