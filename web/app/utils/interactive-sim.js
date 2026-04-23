/**
 * Interactive differential-drive simulator with ray-cast laser.
 * Uses a 100×100 binary occupancy map for the environment.
 */

// Map parameters (100×100 grid, each cell = 100mm = 10cm, total 10m×10m)
const CELL_SIZE = 100; // mm per cell
const MAP_ROWS = 100;
const MAP_COLS = 100;

// Robot physical parameters (same as real robot)
const AXLE_HALF = 260; // mm, half the wheel separation
const ROBOT_RADIUS = 200; // mm, collision radius

// Laser parameters (matching the real 240° scanner)
const LASER_FOV = (240 * Math.PI) / 180;
const LASER_RAYS = 181; // fewer rays than real (683) for perf in real-time
const LASER_MAX = 5000; // mm max range

/**
 * Parse the map JSON into a usable format.
 * map[row][col]: 0 = free, 1 = occupied
 * Row 0 = bottom of world (y=0), row 99 = top (y=10000)
 * We flip rows so row index matches y-up convention.
 */
export function parseMap(mapJson) {
  const raw = mapJson.map;
  // Flip so row 0 = bottom
  const grid = raw.slice().reverse();
  return grid;
}

/**
 * Check if a world coordinate is inside an occupied cell.
 */
export function isOccupied(grid, wx, wy) {
  const col = Math.floor(wx / CELL_SIZE);
  const row = Math.floor(wy / CELL_SIZE);
  if (row < 0 || row >= MAP_ROWS || col < 0 || col >= MAP_COLS) return true; // out of bounds = wall
  return grid[row][col] > 0;
}

/**
 * Check if a circle (robot body) collides with any wall.
 */
export function isColliding(grid, wx, wy) {
  // Check 8 points around the perimeter + center
  const offsets = [
    [0, 0],
    [ROBOT_RADIUS, 0], [-ROBOT_RADIUS, 0],
    [0, ROBOT_RADIUS], [0, -ROBOT_RADIUS],
    [ROBOT_RADIUS * 0.707, ROBOT_RADIUS * 0.707],
    [-ROBOT_RADIUS * 0.707, ROBOT_RADIUS * 0.707],
    [ROBOT_RADIUS * 0.707, -ROBOT_RADIUS * 0.707],
    [-ROBOT_RADIUS * 0.707, -ROBOT_RADIUS * 0.707],
  ];
  for (const [dx, dy] of offsets) {
    if (isOccupied(grid, wx + dx, wy + dy)) return true;
  }
  return false;
}

/**
 * Ray-cast a single ray using DDA through the grid.
 * Returns distance to first hit (mm), or LASER_MAX if nothing hit.
 */
function castRay(grid, ox, oy, angle) {
  const stepSize = CELL_SIZE * 0.4; // sub-cell stepping for accuracy
  const dx = Math.cos(angle) * stepSize;
  const dy = Math.sin(angle) * stepSize;

  // Step through cells using DDA
  let x = ox, y = oy;
  const maxSteps = Math.ceil(LASER_MAX / stepSize);

  for (let s = 1; s <= maxSteps; s++) {
    x += dx;
    y += dy;

    const col = Math.floor(x / CELL_SIZE);
    const row = Math.floor(y / CELL_SIZE);

    if (row < 0 || row >= MAP_ROWS || col < 0 || col >= MAP_COLS) {
      return Math.sqrt((x - ox) ** 2 + (y - oy) ** 2);
    }

    if (grid[row][col] > 0) {
      return Math.sqrt((x - ox) ** 2 + (y - oy) ** 2);
    }
  }

  return -1; // No hit within LASER_MAX
}

/**
 * Simulate a full laser scan from position (rx, ry) at heading rTheta.
 * Returns { ranges, lx, ly } in robot-local frame AND world frame.
 */
export function simulateLaser(grid, rx, ry, rTheta) {
  const ranges = [];
  const wx = [], wy = [];
  const angleStep = LASER_FOV / (LASER_RAYS - 1);
  const startAngle = rTheta - LASER_FOV / 2;

  for (let i = 0; i < LASER_RAYS; i++) {
    const angle = startAngle + i * angleStep;
    const dist = castRay(grid, rx, ry, angle);
    ranges.push(dist);
    if (dist !== -1) {
      wx.push(rx + dist * Math.cos(angle));
      wy.push(ry + dist * Math.sin(angle));
    }
  }

  return { ranges, wx, wy };
}

/**
 * Apply differential-drive kinematics for one timestep.
 * vL, vR: left/right wheel velocities (mm/tick)
 * Returns new { x, y, theta } or null if collision.
 */
export function driveStep(grid, x, y, theta, vL, vR) {
  const dTheta = (vR - vL) / (2 * AXLE_HALF);
  const dist = (vR + vL) / 2;
  const newTheta = theta + dTheta;
  const newX = x + Math.cos(newTheta) * dist;
  const newY = y + Math.sin(newTheta) * dist;

  if (isColliding(grid, newX, newY)) {
    return null; // blocked
  }

  return { x: newX, y: newY, theta: newTheta };
}

/**
 * Find a good starting position (free cell near center).
 */
export function findStartPosition(grid) {
  // Try center of map first, then spiral out
  const cx = 50, cy = 50;
  for (let r = 0; r < 30; r++) {
    for (let dr = -r; dr <= r; dr++) {
      for (let dc = -r; dc <= r; dc++) {
        const row = cy + dr;
        const col = cx + dc;
        if (row >= 2 && row < MAP_ROWS - 2 && col >= 2 && col < MAP_COLS - 2) {
          const wx = (col + 0.5) * CELL_SIZE;
          const wy = (row + 0.5) * CELL_SIZE;
          if (!isColliding(grid, wx, wy)) {
            return { x: wx, y: wy, theta: 0 };
          }
        }
      }
    }
  }
  return { x: 5000, y: 5000, theta: 0 }; // fallback
}

/** Draw the map walls on the canvas context (already in world coords). */
export function drawMap(ctx, grid, cam) {
  ctx.fillStyle = 'rgba(100,100,120,0.6)';
  ctx.beginPath();
  for (let row = 0; row < MAP_ROWS; row++) {
    for (let col = 0; col < MAP_COLS; col++) {
      if (grid[row][col] > 0) {
        ctx.rect(col * CELL_SIZE, row * CELL_SIZE, CELL_SIZE, CELL_SIZE);
      }
    }
  }
  ctx.fill();
}

export { CELL_SIZE, MAP_ROWS, MAP_COLS, LASER_MAX, LASER_RAYS, ROBOT_RADIUS, AXLE_HALF };
