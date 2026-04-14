/**
 * Wall-following controller.
 * Based on fib/ROB/entregas/Pose_Laser/WallFollowing_LE.py
 */

// Distance thresholds (mm)
const TH_LATERAL = 375;
const TH_CENTRAL = 675;
const TH_DIAG = 525;
const TH_RANGE = 20;

// Motor speed limits (mm)
const MAX_CENTRAL = 700;
const MAX_DIAG = 200;
const MAX_LATERAL = 100;

/**
 * Compute wall-following motor commands.
 * @param {number} centralDist - Distance ahead (mm), -1 = no reading
 * @param {number} diagDist - Diagonal distance (mm)
 * @param {number} leftDist - Left wall distance (mm)
 * @returns {{ leftMotor: number, rightMotor: number, k1: number, k2: number, k3: number }}
 */
export function wallFollowingStep(centralDist, diagDist, leftDist) {
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
  if (leftDist > TH_LATERAL - TH_RANGE && leftDist < TH_LATERAL + TH_RANGE) {
    k2 = 0;
  } else if (leftDist > -1 && leftDist <= TH_LATERAL - TH_RANGE) {
    k2 = -(1 - leftDist / TH_LATERAL);
  } else if (leftDist === -1) {
    k2 = 0.5;
  } else {
    k2 = 1 - leftDist / TH_LATERAL;
  }

  // k3: wall tracking (turn left when no wall)
  let k3 = 0;
  if (diagDist < TH_DIAG && diagDist !== -1) {
    k3 = 0;
  } else {
    k3 = 0.7;
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
