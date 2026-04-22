/**
 * Wall-following controller.
 * Based on fib/ROB/entregas/Pose_Laser/WallFollowing_LE.py
 */

// Default distance thresholds (mm)
export const DEFAULTS = {
  thLateral: 375,
  thCentral: 675,
  thDiag: 525,
  thRange: 20,
  maxCentral: 700,
  maxDiag: 200,
  maxLateral: 100,
};

/**
 * Compute wall-following motor commands.
 * @param {number} centralDist - Distance ahead (mm), -1 = no reading
 * @param {number} diagDist - Diagonal distance (mm)
 * @param {number} leftDist - Left wall distance (mm)
 * @param {object} [opts] - Tunable parameters (uses DEFAULTS if omitted)
 * @returns {{ leftMotor: number, rightMotor: number, k1: number, k2: number, k3: number }}
 */
export function wallFollowingStep(centralDist, diagDist, leftDist, opts = {}) {
  const TH_LATERAL = opts.thLateral ?? DEFAULTS.thLateral;
  const TH_CENTRAL = opts.thCentral ?? DEFAULTS.thCentral;
  const TH_DIAG = opts.thDiag ?? DEFAULTS.thDiag;
  const TH_RANGE = opts.thRange ?? DEFAULTS.thRange;
  const MAX_CENTRAL = opts.maxCentral ?? DEFAULTS.maxCentral;
  const MAX_DIAG = opts.maxDiag ?? DEFAULTS.maxDiag;
  const MAX_LATERAL = opts.maxLateral ?? DEFAULTS.maxLateral;
  // k1: obstacle avoidance (turn right)
  let k1 = 0;
  if (centralDist > -1 && centralDist < TH_CENTRAL) {
    k1 = 1 - centralDist / TH_CENTRAL;
  } else if (diagDist > -1 && diagDist < TH_DIAG) {
    k1 = 1 - diagDist / TH_DIAG;
  } else if (leftDist > -1 && leftDist < TH_DIAG) {
    k1 = (1 - leftDist / TH_LATERAL) * 0.5;
  }

  // k2: distance maintenance
  let k2 = 0;
  if (leftDist === -1) {
    k2 = -0.5; // turn left to find wall
  } else if (leftDist > TH_LATERAL - TH_RANGE && leftDist < TH_LATERAL + TH_RANGE) {
    k2 = 0;
  } else {
    k2 = 1 - leftDist / TH_LATERAL;
  }

  // k3: wall tracking (turn left when no wall)
  let k3 = 0;
  if (diagDist < TH_DIAG && diagDist !== -1) {
    k3 = 0;
  } else {
    k3 = -0.7;
  }

  const leftMotor = MAX_CENTRAL + k1 * MAX_DIAG + k2 * MAX_LATERAL + k3 * MAX_LATERAL;
  const rightMotor = MAX_CENTRAL - k1 * MAX_DIAG - k2 * MAX_LATERAL - k3 * MAX_LATERAL;

  return { leftMotor, rightMotor, k1, k2, k3 };
}

/**
 * Extract sensor readings from a laser scan array for wall-following.
 * Expects 9 readings: [central, diag_right, right, back_right, back, back_left, left, diag_left, front_left]
 * Or use indices: central=0, diagLeft=7, left=6
 */
export function extractWallDistances(readings) {
  return {
    centralDist: readings[0] ?? -1,
    diagDist: readings[7] ?? -1,
    leftDist: readings[6] ?? -1,
  };
}
