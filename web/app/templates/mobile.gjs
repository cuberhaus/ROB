import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { on } from '@ember/modifier';
import { didInsert } from '@ember/render-modifiers';
import { buildTrajectory, laserToCartesian, transformPoints } from '../utils/odometry';
import { setupCanvas, createCamera, applyCamera, drawArrow } from '../utils/canvas-helpers';
import {
  parseMap, simulateLaser, driveStep, findStartPosition, drawMap,
  CELL_SIZE, MAP_ROWS, MAP_COLS, LASER_MAX, ROBOT_RADIUS, AXLE_HALF,
} from '../utils/interactive-sim';

// Occupancy grid config
const GRID_RES = 50;       // mm per cell
const GRID_SIZE = 300;     // 300x300 cells = 15m x 15m
const GRID_ORIGIN = -7500; // grid[0][0] corresponds to (-7500, -7500) mm

class MobilePage extends Component {
  @tracked playing = false;
  @tracked step = 0;
  @tracked maxStep = 0;
  @tracked loaded = false;
  @tracked speed = 5;
  @tracked showGrid = true;
  @tracked mode = 'replay'; // 'replay' | 'interactive'

  canvas = null;
  trajCanvas = null;
  camera = createCamera(0, 0, 0.08);
  trajectory = null;
  sensorData = null;
  animId = null;
  W = 700;
  H = 500;

  // Occupancy grid: counts of laser hits per cell
  occGrid = null;
  _lastGridStep = -1;  // track which steps we've already accumulated

  // Interactive mode state
  mapGrid = null;
  @tracked simX = 0;
  @tracked simY = 0;
  @tracked simTheta = 0;
  @tracked simVL = 0; // left wheel speed display
  @tracked simVR = 0; // right wheel speed display
  simTrailX = [];
  simTrailY = [];
  simLaser = null; // { ranges, wx, wy }
  _keys = {};      // currently pressed keys
  _simRunning = false;
  // Occupancy grid built by interactive laser
  simOccGrid = null;

  // Mouse pan state
  _dragging = false;
  _dragStart = { x: 0, y: 0 };

  @action
  async setup(el) {
    this.canvas = el.querySelector('#mobile-canvas');
    this.trajCanvas = el.querySelector('#traj-canvas');

    // Pan/zoom handlers
    this.canvas.addEventListener('mousedown', (e) => this.onMouseDown(e));
    this.canvas.addEventListener('mousemove', (e) => this.onMouseMove(e));
    this.canvas.addEventListener('mouseup', () => this.onMouseUp());
    this.canvas.addEventListener('mouseleave', () => this.onMouseUp());
    this.canvas.addEventListener('wheel', (e) => this.onWheel(e), { passive: false });

    try {
      const [encRes, sensRes, wpRes, mapRes] = await Promise.all([
        fetch('/data/encoder.json'),
        fetch('/data/sensors.json'),
        fetch('/data/waypoints.json'),
        fetch('/data/map1.json'),
      ]);
      const enc = await encRes.json();
      const sens = await sensRes.json();
      const wp = await wpRes.json();
      const mapJson = await mapRes.json();

      this.trajectory = buildTrajectory(enc.L_acu, enc.R_acu);
      this.encoderRaw = enc;
      this.sensorData = sens;
      this.waypoints = wp.waypoints;
      this.maxStep = this.trajectory.x.length - 1;

      // Parse map for interactive mode
      this.mapGrid = parseMap(mapJson);
      const start = findStartPosition(this.mapGrid);
      this.simX = start.x;
      this.simY = start.y;
      this.simTheta = start.theta;
      this.simTrailX = [start.x];
      this.simTrailY = [start.y];
      this._initSimOccGrid();

      this.loaded = true;
      this._initGrid();

      // Auto-center camera
      const xs = this.trajectory.x;
      const ys = this.trajectory.y;
      const minX = Math.min(...xs), maxX = Math.max(...xs);
      const minY = Math.min(...ys), maxY = Math.max(...ys);
      this.camera.cx = (minX + maxX) / 2;
      this.camera.cy = (minY + maxY) / 2;
      const rangeX = maxX - minX || 1;
      const rangeY = maxY - minY || 1;
      this.camera.scale = Math.min(this.W / rangeX, this.H / rangeY) * 0.8;

      this.draw();
      this.drawTrajectory();

      // Keyboard handlers for interactive mode
      this._onKeyDown = (e) => this._handleKeyDown(e);
      this._onKeyUp = (e) => this._handleKeyUp(e);
      document.addEventListener('keydown', this._onKeyDown);
      document.addEventListener('keyup', this._onKeyUp);
    } catch (e) {
      console.error('Failed to load data:', e);
    }
  }

  willDestroy() {
    super.willDestroy?.();
    cancelAnimationFrame(this.animId);
    this._stopSimLoop();
    if (this._onKeyDown) document.removeEventListener('keydown', this._onKeyDown);
    if (this._onKeyUp) document.removeEventListener('keyup', this._onKeyUp);
  }

  @action
  togglePlay() {
    this.playing = !this.playing;
    if (this.playing) this.animate();
    else cancelAnimationFrame(this.animId);
  }

  @action
  reset() {
    this.playing = false;
    cancelAnimationFrame(this.animId);
    this.step = 0;
    this._initGrid();
    this.draw();
  }

  @action
  toggleGrid() {
    this.showGrid = !this.showGrid;
    this.draw();
  }

  _initGrid() {
    this.occGrid = new Float32Array(GRID_SIZE * GRID_SIZE);
    this._lastGridStep = -1;
  }

  _accumulateGrid(upToStep) {
    if (!this.sensorData || !this.trajectory) return;
    const scan = this.sensorData.polar_laser_data;
    const { x, y, theta } = this.trajectory;
    const startStep = this._lastGridStep + 1;

    // We only accumulate for scan-aligned steps (every ~20 encoder steps ≈ 1 scan)
    const scanCount = scan.length;
    for (let s = startStep; s <= upToStep; s += 5) {
      const scanIdx = Math.min(
        Math.floor((s / this.maxStep) * (scanCount - 1)),
        scanCount - 1,
      );
      if (!scan[scanIdx]) continue;
      const ranges = scan[scanIdx];
      const { lx, ly } = laserToCartesian(ranges);
      const { wx, wy } = transformPoints(lx, ly, x[s], y[s], theta[s]);
      for (let j = 0; j < wx.length; j++) {
        const gx = Math.floor((wx[j] - GRID_ORIGIN) / GRID_RES);
        const gy = Math.floor((wy[j] - GRID_ORIGIN) / GRID_RES);
        if (gx >= 0 && gx < GRID_SIZE && gy >= 0 && gy < GRID_SIZE) {
          this.occGrid[gy * GRID_SIZE + gx] += 1;
        }
      }
    }
    this._lastGridStep = upToStep;
  }

  // ── Interactive mode ──────────────────────────────────────────────

  @action
  switchMode() {
    this.mode = this.mode === 'replay' ? 'interactive' : 'replay';
    if (this.mode === 'interactive') {
      // Stop replay
      this.playing = false;
      cancelAnimationFrame(this.animId);
      // Center camera on map
      const mapW = MAP_COLS * CELL_SIZE;
      const mapH = MAP_ROWS * CELL_SIZE;
      this.camera.cx = mapW / 2;
      this.camera.cy = mapH / 2;
      this.camera.scale = Math.min(this.W / mapW, this.H / mapH) * 0.85;
      this._startSimLoop();
    } else {
      this._stopSimLoop();
      // Re-center on replay trajectory
      if (this.trajectory) {
        const xs = this.trajectory.x;
        const ys = this.trajectory.y;
        const minX = Math.min(...xs), maxX = Math.max(...xs);
        const minY = Math.min(...ys), maxY = Math.max(...ys);
        this.camera.cx = (minX + maxX) / 2;
        this.camera.cy = (minY + maxY) / 2;
        const rangeX = maxX - minX || 1;
        const rangeY = maxY - minY || 1;
        this.camera.scale = Math.min(this.W / rangeX, this.H / rangeY) * 0.8;
      }
      this.draw();
    }
  }

  @action
  resetSim() {
    if (!this.mapGrid) return;
    const start = findStartPosition(this.mapGrid);
    this.simX = start.x;
    this.simY = start.y;
    this.simTheta = start.theta;
    this.simTrailX = [start.x];
    this.simTrailY = [start.y];
    this.simLaser = null;
    this._initSimOccGrid();
  }

  _initSimOccGrid() {
    // Map-aligned grid: one entry per map cell (100×100)
    this.simOccGrid = new Float32Array(MAP_ROWS * MAP_COLS);
  }

  _handleKeyDown(e) {
    if (this.mode !== 'interactive') return;
    if (['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'w', 'a', 's', 'd'].includes(e.key)) {
      e.preventDefault();
      this._keys[e.key] = true;
    }
  }

  _handleKeyUp(e) {
    this._keys[e.key] = false;
  }

  _startSimLoop() {
    if (this._simRunning) return;
    this._simRunning = true;
    const tick = () => {
      if (!this._simRunning) return;
      this._simTick();
      this._simAnimId = requestAnimationFrame(tick);
    };
    tick();
  }

  _stopSimLoop() {
    this._simRunning = false;
    if (this._simAnimId) cancelAnimationFrame(this._simAnimId);
  }

  _simTick() {
    if (!this.mapGrid) return;

    // Read keyboard → compute wheel velocities
    const k = this._keys;
    const FWD = 25;  // mm per tick forward speed
    const TURN = 15; // mm per tick differential for turning
    let vL = 0, vR = 0;

    if (k['ArrowUp'] || k['w']) { vL += FWD; vR += FWD; }
    if (k['ArrowDown'] || k['s']) { vL -= FWD; vR -= FWD; }
    if (k['ArrowLeft'] || k['a']) { vL -= TURN; vR += TURN; }
    if (k['ArrowRight'] || k['d']) { vL += TURN; vR -= TURN; }

    this.simVL = vL;
    this.simVR = vR;

    // Apply differential-drive kinematics
    if (vL !== 0 || vR !== 0) {
      const result = driveStep(this.mapGrid, this.simX, this.simY, this.simTheta, vL, vR);
      if (result) {
        this.simX = result.x;
        this.simY = result.y;
        this.simTheta = result.theta;
        this.simTrailX.push(result.x);
        this.simTrailY.push(result.y);
        // Keep trail bounded
        if (this.simTrailX.length > 5000) {
          this.simTrailX = this.simTrailX.slice(-4000);
          this.simTrailY = this.simTrailY.slice(-4000);
        }
      }
    }

    // Ray-cast laser
    this.simLaser = simulateLaser(this.mapGrid, this.simX, this.simY, this.simTheta);

    // Accumulate laser hits into occupancy grid (use map-aligned grid for interactive)
    if (this.simLaser && this.simOccGrid) {
      const { wx, wy } = this.simLaser;
      for (let j = 0; j < wx.length; j++) {
        const gx = Math.floor(wx[j] / CELL_SIZE);
        const gy = Math.floor(wy[j] / CELL_SIZE);
        if (gx >= 0 && gx < MAP_COLS && gy >= 0 && gy < MAP_ROWS) {
          this.simOccGrid[gy * MAP_COLS + gx] += 0.3;
        }
      }
    }

    // Auto-follow camera (smooth)
    const followSpeed = 0.08;
    this.camera.cx += (this.simX - this.camera.cx) * followSpeed;
    this.camera.cy += (this.simY - this.camera.cy) * followSpeed;

    this.drawInteractive();
  }

  drawInteractive() {
    if (!this.canvas || !this.mapGrid) return;
    const ctx = setupCanvas(this.canvas, this.W, this.H);
    const cam = this.camera;
    applyCamera(ctx, cam, this.W, this.H);

    // Draw map walls
    drawMap(ctx, this.mapGrid, cam);

    // Draw built-up occupancy grid from interactive scans
    if (this.showGrid && this.simOccGrid) {
      const maxHits = 6;
      for (let gy = 0; gy < MAP_ROWS; gy++) {
        for (let gx = 0; gx < MAP_COLS; gx++) {
          const val = this.simOccGrid[gy * MAP_COLS + gx];
          if (val <= 0) continue;
          const intensity = Math.min(val / maxHits, 1);
          ctx.fillStyle = `rgba(77,171,247,${0.15 + 0.5 * intensity})`;
          ctx.fillRect(gx * CELL_SIZE, gy * CELL_SIZE, CELL_SIZE, CELL_SIZE);
        }
      }
    }

    // Draw trail
    const tx = this.simTrailX, ty = this.simTrailY;
    if (tx.length > 1) {
      ctx.strokeStyle = '#4dabf7';
      ctx.lineWidth = 2 / cam.scale;
      ctx.beginPath();
      ctx.moveTo(tx[0], ty[0]);
      for (let j = 1; j < tx.length; j++) {
        ctx.lineTo(tx[j], ty[j]);
      }
      ctx.stroke();
    }

    // Draw laser
    if (this.simLaser) {
      const { wx, wy } = this.simLaser;
      // Rays
      ctx.strokeStyle = 'rgba(105,219,124,0.12)';
      ctx.lineWidth = 0.5 / cam.scale;
      for (let j = 0; j < wx.length; j += 2) {
        ctx.beginPath();
        ctx.moveTo(this.simX, this.simY);
        ctx.lineTo(wx[j], wy[j]);
        ctx.stroke();
      }
      // Hit points
      ctx.fillStyle = 'rgba(105,219,124,0.6)';
      for (let j = 0; j < wx.length; j++) {
        ctx.beginPath();
        ctx.arc(wx[j], wy[j], 4, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    // Draw robot body
    ctx.beginPath();
    ctx.arc(this.simX, this.simY, ROBOT_RADIUS, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(255,107,107,0.15)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(255,107,107,0.5)';
    ctx.lineWidth = 1.5 / cam.scale;
    ctx.stroke();

    // Wheels
    const wheelLen = 60, wheelW = 12;
    ctx.save();
    ctx.translate(this.simX, this.simY);
    ctx.rotate(this.simTheta);
    // Color wheels based on speed
    ctx.fillStyle = this.simVL > 0 ? '#69db7c' : this.simVL < 0 ? '#ff8787' : '#666';
    ctx.fillRect(-wheelLen / 2, AXLE_HALF - wheelW / 2, wheelLen, wheelW);
    ctx.fillStyle = this.simVR > 0 ? '#69db7c' : this.simVR < 0 ? '#ff8787' : '#666';
    ctx.fillRect(-wheelLen / 2, -AXLE_HALF - wheelW / 2, wheelLen, wheelW);
    ctx.restore();

    // Heading arrow
    ctx.fillStyle = '#ff6b6b';
    drawArrow(ctx, this.simX, this.simY, this.simTheta, 60 / cam.scale * 0.3);

    // Velocity vector
    if (this.simVL !== 0 || this.simVR !== 0) {
      const v = (this.simVL + this.simVR) / 2;
      const vx = Math.cos(this.simTheta) * v * 5;
      const vy = Math.sin(this.simTheta) * v * 5;
      ctx.strokeStyle = '#ffa94d';
      ctx.lineWidth = 2.5 / cam.scale;
      ctx.beginPath();
      ctx.moveTo(this.simX, this.simY);
      ctx.lineTo(this.simX + vx, this.simY + vy);
      ctx.stroke();
    }
  }

  @action
  onSlider(e) {
    this.step = parseInt(e.target.value, 10);
    this.draw();
  }

  @action
  onSpeed(e) {
    this.speed = parseInt(e.target.value, 10);
  }

  animate() {
    if (!this.playing) return;
    this.step = Math.min(this.step + this.speed, this.maxStep);
    if (this.step >= this.maxStep) { this.playing = false; }
    this.draw();
    this.animId = requestAnimationFrame(() => this.animate());
  }

  onMouseDown(e) {
    this._dragging = true;
    this._dragStart = { x: e.clientX, y: e.clientY };
  }

  onMouseMove(e) {
    if (!this._dragging) return;
    const dx = e.clientX - this._dragStart.x;
    const dy = e.clientY - this._dragStart.y;
    this._dragStart = { x: e.clientX, y: e.clientY };
    // Convert screen pixels to world coordinates (camera has flipped y)
    this.camera.cx -= dx / this.camera.scale;
    this.camera.cy += dy / this.camera.scale;
    this.draw();
  }

  onMouseUp() {
    this._dragging = false;
  }

  onWheel(e) {
    e.preventDefault();
    const factor = e.deltaY > 0 ? 0.9 : 1.1;
    this.camera.scale *= factor;
    this.draw();
  }

  draw() {
    if (!this.canvas || !this.trajectory) return;
    const ctx = setupCanvas(this.canvas, this.W, this.H);
    const cam = this.camera;
    applyCamera(ctx, cam, this.W, this.H);

    const { x, y, theta } = this.trajectory;
    const i = this.step;

    // Accumulate occupancy grid up to current step
    if (this.occGrid && i > this._lastGridStep) {
      this._accumulateGrid(i);
    }

    // Draw occupancy grid (built-up map)
    if (this.showGrid && this.occGrid) {
      const maxHits = 8; // saturate color at this many hits
      for (let gy = 0; gy < GRID_SIZE; gy++) {
        for (let gx = 0; gx < GRID_SIZE; gx++) {
          const val = this.occGrid[gy * GRID_SIZE + gx];
          if (val <= 0) continue;
          const intensity = Math.min(val / maxHits, 1);
          const r = Math.round(255 * intensity);
          const g = Math.round(100 * (1 - intensity));
          const b = Math.round(50 * (1 - intensity));
          ctx.fillStyle = `rgba(${r},${g},${b},${0.3 + 0.6 * intensity})`;
          const wx = GRID_ORIGIN + gx * GRID_RES;
          const wy = GRID_ORIGIN + gy * GRID_RES;
          ctx.fillRect(wx, wy, GRID_RES, GRID_RES);
        }
      }
    }

    // Draw waypoints
    if (this.waypoints) {
      ctx.fillStyle = 'rgba(255,212,59,0.6)';
      const wp = this.waypoints;
      for (let j = 0; j < wp[0].length; j++) {
        ctx.beginPath();
        ctx.arc(wp[0][j], wp[1][j], 30, 0, Math.PI * 2);
        ctx.fill();
        // Waypoint label
        ctx.save();
        ctx.translate(wp[0][j], wp[1][j]);
        ctx.scale(1 / cam.scale, -1 / cam.scale);
        ctx.fillStyle = '#ffd43b';
        ctx.font = 'bold 10px Inter, sans-serif';
        ctx.textAlign = 'center';
        ctx.fillText(`WP${j + 1}`, 0, -6);
        ctx.restore();
      }
    }

    // Draw trail
    ctx.strokeStyle = '#4dabf7';
    ctx.lineWidth = 2 / cam.scale;
    ctx.beginPath();
    for (let j = 0; j <= i; j++) {
      j === 0 ? ctx.moveTo(x[j], y[j]) : ctx.lineTo(x[j], y[j]);
    }
    ctx.stroke();

    // Draw laser scan at current position (closest scan index)
    if (this.sensorData) {
      const scan = this.sensorData.polar_laser_data;
      const scanIdx = Math.min(
        Math.floor((i / this.maxStep) * (scan.length - 1)),
        scan.length - 1,
      );
      if (scan[scanIdx]) {
        const ranges = scan[scanIdx];
        const { lx, ly } = laserToCartesian(ranges);
        const { wx, wy } = transformPoints(lx, ly, x[i], y[i], theta[i]);
        // Draw laser rays from robot to hit points
        ctx.strokeStyle = 'rgba(105,219,124,0.15)';
        ctx.lineWidth = 0.5 / cam.scale;
        for (let j = 0; j < wx.length; j += 3) {
          ctx.beginPath();
          ctx.moveTo(x[i], y[i]);
          ctx.lineTo(wx[j], wy[j]);
          ctx.stroke();
        }
        // Draw hit points
        ctx.fillStyle = 'rgba(105,219,124,0.5)';
        for (let j = 0; j < wx.length; j++) {
          ctx.beginPath();
          ctx.arc(wx[j], wy[j], 6, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    }

    // Draw robot body (circle + arrow)
    const robotR = 80;
    ctx.beginPath();
    ctx.arc(x[i], y[i], robotR, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(255,107,107,0.15)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(255,107,107,0.5)';
    ctx.lineWidth = 1.5 / cam.scale;
    ctx.stroke();

    // Draw wheel indicators
    const wheelLen = 60, wheelW = 12;
    const S = 121.5;
    ctx.save();
    ctx.translate(x[i], y[i]);
    ctx.rotate(theta[i]);
    ctx.fillStyle = '#666';
    // Left wheel
    ctx.fillRect(-wheelLen / 2, S - wheelW / 2, wheelLen, wheelW);
    // Right wheel
    ctx.fillRect(-wheelLen / 2, -S - wheelW / 2, wheelLen, wheelW);
    ctx.restore();

    // Draw velocity vector
    if (i > 0) {
      const dx = x[i] - x[i - 1];
      const dy = y[i] - y[i - 1];
      const v = Math.sqrt(dx * dx + dy * dy);
      const vScale = 15; // exaggerate for visibility
      if (v > 0.1) {
        ctx.strokeStyle = '#ffa94d';
        ctx.lineWidth = 2.5 / cam.scale;
        ctx.beginPath();
        ctx.moveTo(x[i], y[i]);
        ctx.lineTo(x[i] + dx * vScale, y[i] + dy * vScale);
        ctx.stroke();
        // Arrowhead
        const angle = Math.atan2(dy, dx);
        const aLen = 30;
        ctx.beginPath();
        ctx.moveTo(x[i] + dx * vScale, y[i] + dy * vScale);
        ctx.lineTo(
          x[i] + dx * vScale - aLen * Math.cos(angle - 0.4),
          y[i] + dy * vScale - aLen * Math.sin(angle - 0.4),
        );
        ctx.moveTo(x[i] + dx * vScale, y[i] + dy * vScale);
        ctx.lineTo(
          x[i] + dx * vScale - aLen * Math.cos(angle + 0.4),
          y[i] + dy * vScale - aLen * Math.sin(angle + 0.4),
        );
        ctx.stroke();
      }

      // Draw angular velocity arc
      const dTheta = theta[i] - theta[i - 1];
      if (Math.abs(dTheta) > 0.001) {
        const arcR = 120;
        ctx.strokeStyle = dTheta > 0 ? '#b197fc' : '#f783ac';
        ctx.lineWidth = 2 / cam.scale;
        ctx.beginPath();
        const startA = theta[i];
        const endA = theta[i] + dTheta * 20; // exaggerate
        ctx.arc(x[i], y[i], arcR, startA, endA, dTheta < 0);
        ctx.stroke();
      }
    }

    // Draw robot heading arrow
    ctx.fillStyle = '#ff6b6b';
    drawArrow(ctx, x[i], y[i], theta[i], 60 / cam.scale * 0.3);
  }

  drawTrajectory() {
    if (!this.trajCanvas || !this.trajectory) return;
    const W = 300, H = 200;
    const ctx = setupCanvas(this.trajCanvas, W, H);

    const { x, y, theta, t } = this.trajectory;
    const n = x.length;

    // Draw x, y, theta over time
    const maxT = t[n - 1] || 1;
    const datasets = [
      { data: x, color: '#4dabf7', label: 'x' },
      { data: y, color: '#69db7c', label: 'y' },
    ];

    for (const ds of datasets) {
      const minV = Math.min(...ds.data);
      const maxV = Math.max(...ds.data);
      const range = maxV - minV || 1;
      ctx.strokeStyle = ds.color;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      for (let i = 0; i < n; i += 10) {
        const px = (t[i] / maxT) * W;
        const py = H - ((ds.data[i] - minV) / range) * (H - 20) - 10;
        i === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
      }
      ctx.stroke();
    }

    // Legend
    ctx.font = '11px Inter, sans-serif';
    ctx.fillStyle = '#4dabf7';
    ctx.fillText('x(t)', 5, 12);
    ctx.fillStyle = '#69db7c';
    ctx.fillText('y(t)', 35, 12);
  }

  <template>
    <div class="page-header">
      <h2>🚗 Mobile Robot Simulator</h2>
      <p>
        {{#if (this.isInteractive)}}
          <strong>🎮 Interactive Mode</strong> — Drive with <kbd>W</kbd><kbd>A</kbd><kbd>S</kbd><kbd>D</kbd> or arrow keys. Camera follows the robot.
        {{else}}
          Replay real encoder &amp; laser data with <strong>live map building</strong>. Drag to pan, scroll to zoom.
        {{/if}}
      </p>
    </div>

    <div {{didInsert this.setup}} class="grid-2">
      <div class="card span-2">
        <div class="controls">
          <button class="primary" type="button" {{on "click" this.switchMode}}>
            {{if (this.isInteractive) "📺 Replay Mode" "🎮 Interactive Mode"}}
          </button>

          {{#if (this.isInteractive)}}
            <button type="button" {{on "click" this.resetSim}}>⏮ Reset Robot</button>
            <button class={{if this.showGrid "primary" ""}} type="button" {{on "click" this.toggleGrid}}>
              {{if this.showGrid "🗺 Hide Scan Map" "🗺 Show Scan Map"}}
            </button>
          {{else}}
            <button class={{if this.playing "primary" ""}} type="button" {{on "click" this.togglePlay}}>
              {{if this.playing "⏸ Pause" "▶ Play"}}
            </button>
            <button type="button" {{on "click" this.reset}}>⏮ Reset</button>
            <button class={{if this.showGrid "primary" ""}} type="button" {{on "click" this.toggleGrid}}>
              {{if this.showGrid "🗺 Hide Map" "🗺 Show Map"}}
            </button>
            <div class="slider-group">
              <label>Step</label>
              <input type="range" min="0" max={{this.maxStep}} value={{this.step}} {{on "input" this.onSlider}}>
              <span class="val">{{this.step}}/{{this.maxStep}}</span>
            </div>
            <div class="slider-group">
              <label>Speed</label>
              <input type="range" min="1" max="50" value={{this.speed}} {{on "input" this.onSpeed}}>
              <span class="val">×{{this.speed}}</span>
            </div>
          {{/if}}
        </div>
        <div class="canvas-legend">
          <span class="legend-item"><span class="dot" style="background:#4dabf7"></span> Trajectory</span>
          <span class="legend-item"><span class="dot" style="background:#69db7c"></span> Laser hits</span>
          <span class="legend-item"><span class="dot" style="background:#ffa94d"></span> Velocity</span>
          {{#unless (this.isInteractive)}}
            <span class="legend-item"><span class="dot" style="background:#b197fc"></span> Turning CCW</span>
            <span class="legend-item"><span class="dot" style="background:#f783ac"></span> Turning CW</span>
          {{/unless}}
          <span class="legend-item"><span class="dot" style="background:#ff6b6b"></span> Robot</span>
          {{#if (this.isInteractive)}}
            <span class="legend-item"><span class="dot" style="background:rgba(100,100,120,0.6)"></span> Walls</span>
          {{/if}}
        </div>
        <div class="canvas-wrap">
          <canvas id="mobile-canvas"></canvas>
        </div>
      </div>

      <div class="card">
        {{#if (this.isInteractive)}}
          <h3 class="card-title">🎮 Controls &amp; State</h3>
          {{#if this.loaded}}
            <div class="kb-controls">
              <div class="kb-row"><kbd class={{if this._fwd "kb-active" ""}}>W / ↑</kbd></div>
              <div class="kb-row">
                <kbd class={{if this._left "kb-active" ""}}>A / ←</kbd>
                <kbd class={{if this._back "kb-active" ""}}>S / ↓</kbd>
                <kbd class={{if this._right "kb-active" ""}}>D / →</kbd>
              </div>
            </div>
            <hr style="border-color:var(--c-border);margin:8px 0">
            <table class="info-table">
              <tr><th>x</th><td>{{this.simPosX}} mm</td></tr>
              <tr><th>y</th><td>{{this.simPosY}} mm</td></tr>
              <tr><th>θ</th><td>{{this.simPosTheta}}°</td></tr>
            </table>
            <hr style="border-color:var(--c-border);margin:8px 0">
            <table class="info-table">
              <tr>
                <th>Left wheel</th>
                <td style="color:{{if this.simVL '#69db7c' '#adb5bd'}}">{{this.simVL}} mm/tick</td>
              </tr>
              <tr>
                <th>Right wheel</th>
                <td style="color:{{if this.simVR '#69db7c' '#adb5bd'}}">{{this.simVR}} mm/tick</td>
              </tr>
            </table>
            <hr style="border-color:var(--c-border);margin:8px 0">
            <div class="motion-phase" style="text-align:center;padding:4px">
              <strong style="font-size:1.2em">{{this.simMotionPhase}}</strong>
            </div>
          {{else}}
            <p>Loading…</p>
          {{/if}}
        {{else}}
          <h3 class="card-title">📐 Pose &amp; Kinematics</h3>
          {{#if this.loaded}}
            <table class="info-table">
              <tr><th>x</th><td>{{this.posX}} mm</td></tr>
              <tr><th>y</th><td>{{this.posY}} mm</td></tr>
              <tr><th>θ</th><td>{{this.posTheta}}°</td></tr>
              <tr><th>Time</th><td>{{this.posTime}} s</td></tr>
            </table>
            <hr style="border-color:var(--c-border);margin:8px 0">
            <table class="info-table">
              <tr><th>v (linear)</th><td>{{this.velocity}} mm/step</td></tr>
              <tr><th>ω (angular)</th><td>{{this.angularVel}} °/step</td></tr>
              <tr><th>ΔL (left enc)</th><td>{{this.deltaL}} mm</td></tr>
              <tr><th>ΔR (right enc)</th><td>{{this.deltaR}} mm</td></tr>
            </table>
            <hr style="border-color:var(--c-border);margin:8px 0">
            <div class="motion-phase" style="text-align:center;padding:4px">
              <strong style="font-size:1.2em">{{this.motionPhase}}</strong>
            </div>
          {{else}}
            <p>Loading data…</p>
          {{/if}}
        {{/if}}
      </div>

      <div class="card">
        <h3 class="card-title">
          {{#if (this.isInteractive)}}
            🏗️ How It Works
          {{else}}
            Position over Time
          {{/if}}
        </h3>
        {{#if (this.isInteractive)}}
          <div style="font-size:0.85em;line-height:1.5;padding:0.5rem">
            <p><strong>You are the motor controller!</strong> Each key press sets wheel velocities:</p>
            <ul>
              <li><kbd>W</kbd> — Both wheels forward → straight line</li>
              <li><kbd>A</kbd> — Left wheel back, right forward → turn left</li>
              <li><kbd>W</kbd>+<kbd>D</kbd> — Forward + right differential → curve right</li>
              <li>The green/red wheel colors show direction per wheel</li>
            </ul>
            <p>The <strong>laser scanner</strong> ray-casts 181 beams against the map walls in real-time.
            Watch the <strong>scan map</strong> build up as you explore — this is how real robots
            discover their environment!</p>
          </div>
        {{else}}
          <div class="canvas-wrap">
            <canvas id="traj-canvas"></canvas>
          </div>
        {{/if}}
      </div>

      <div class="card span-2" style="font-size:0.85em;line-height:1.5">
        <h3 class="card-title">📖 What's Happening?</h3>
        <details open>
          <summary><strong>Differential-Drive Odometry</strong></summary>
          <p>The robot has two independently driven wheels separated by <strong>2S = 243 mm</strong>.
          At each timestep, the left (ΔL) and right (ΔR) wheel encoder increments are used to compute:</p>
          <ul>
            <li><strong>Δθ = (ΔR − ΔL) / 2S</strong> — heading change (if ΔR &gt; ΔL, the robot turns left)</li>
            <li><strong>d = (ΔR + ΔL) / 2</strong> — distance traveled by the midpoint</li>
            <li><strong>Δx = d · cos(θ + Δθ)</strong>, <strong>Δy = d · sin(θ + Δθ)</strong> — position update</li>
          </ul>
          <p>This is <em>dead reckoning</em> — it accumulates error over time since there's no external correction.
          {{#if (this.isInteractive)}} <strong>Try it now: drive in a big loop and see if the robot returns to the start!</strong>{{/if}}</p>
        </details>
        <details>
          <summary><strong>Laser Range Scanner (LIDAR)</strong></summary>
          <p>A 240° laser scanner fires <strong>{{#if (this.isInteractive)}}181{{else}}683{{/if}} rays</strong> and measures distance to obstacles.
          Each ray gives a polar reading (angle, distance) converted to Cartesian points.
          The green dots show where laser beams hit walls/objects.</p>
          <p>As the robot moves, laser hits are accumulated into an <strong>occupancy grid</strong> — the heatmap you see building up.
          Brighter = more laser hits = higher confidence that something solid is there. This is the basis of <strong>SLAM</strong> (Simultaneous Localization And Mapping).</p>
        </details>
        <details>
          <summary><strong>Visual Legend</strong></summary>
          <ul>
            <li>🔴 <strong>Red arrow</strong> = robot position + heading</li>
            <li>🟠 <strong>Orange arrow</strong> = instantaneous velocity vector</li>
            {{#unless (this.isInteractive)}}
              <li>🟣 <strong>Purple/pink arc</strong> = angular velocity (turning)</li>
            {{/unless}}
            <li>🔵 <strong>Blue trail</strong> = odometry trajectory (accumulated path)</li>
            <li>🟢 <strong>Green dots</strong> = current laser scan hits with faint rays</li>
            {{#unless (this.isInteractive)}}
              <li>🟡 <strong>Yellow circles</strong> = navigation waypoints</li>
            {{/unless}}
            <li>🗺️ <strong>Heatmap</strong> = occupancy grid built from accumulated scans</li>
            {{#if (this.isInteractive)}}
              <li>⬛ <strong>Grey blocks</strong> = map walls (ground truth)</li>
              <li>🟩/🟥 <strong>Wheel color</strong> = forward (green) / backward (red)</li>
            {{/if}}
          </ul>
        </details>
      </div>
    </div>
  </template>

  get posX() {
    if (!this.trajectory) return '—';
    return this.trajectory.x[this.step]?.toFixed(1) ?? '—';
  }
  get posY() {
    if (!this.trajectory) return '—';
    return this.trajectory.y[this.step]?.toFixed(1) ?? '—';
  }
  get posTheta() {
    if (!this.trajectory) return '—';
    return ((this.trajectory.theta[this.step] ?? 0) * 180 / Math.PI).toFixed(1);
  }
  get posTime() {
    if (!this.trajectory) return '—';
    return this.trajectory.t[this.step]?.toFixed(2) ?? '—';
  }

  // ── Interactive mode computed properties ──────────────────────────

  get isInteractive() {
    return this.mode === 'interactive';
  }

  get simPosX() {
    return this.simX.toFixed(0);
  }

  get simPosY() {
    return this.simY.toFixed(0);
  }

  get simPosTheta() {
    return (this.simTheta * 180 / Math.PI).toFixed(1);
  }

  get _fwd() {
    return this._keys['ArrowUp'] || this._keys['w'];
  }
  get _back() {
    return this._keys['ArrowDown'] || this._keys['s'];
  }
  get _left() {
    return this._keys['ArrowLeft'] || this._keys['a'];
  }
  get _right() {
    return this._keys['ArrowRight'] || this._keys['d'];
  }

  get simMotionPhase() {
    const vL = this.simVL, vR = this.simVR;
    if (vL === 0 && vR === 0) return '⏸ Stopped';
    if (Math.sign(vL) !== Math.sign(vR) && vL !== 0 && vR !== 0) return '🔄 Turning in place';
    if (Math.abs(vL - vR) > 5) return '↩️ Curving';
    return '➡️ Driving straight';
  }

  get velocity() {
    if (!this.trajectory || this.step < 1) return '0.0';
    const { x, y } = this.trajectory;
    const i = this.step;
    const dx = x[i] - x[i - 1];
    const dy = y[i] - y[i - 1];
    return Math.sqrt(dx * dx + dy * dy).toFixed(1);
  }

  get angularVel() {
    if (!this.trajectory || this.step < 1) return '0.0';
    const dTheta = this.trajectory.theta[this.step] - this.trajectory.theta[this.step - 1];
    return (dTheta * 180 / Math.PI).toFixed(2);
  }

  get deltaL() {
    if (!this.encoderRaw || this.step < 1) return '—';
    const L = this.encoderRaw.L_acu;
    const i = this.step;
    if (i >= L.length) return '—';
    return (L[i][1] - L[i - 1][1]).toFixed(1);
  }

  get deltaR() {
    if (!this.encoderRaw || this.step < 1) return '—';
    const R = this.encoderRaw.R_acu;
    const i = this.step;
    if (i >= R.length) return '—';
    return (R[i][1] - R[i - 1][1]).toFixed(1);
  }

  get motionPhase() {
    if (!this.trajectory || this.step < 1) return '⏸ Stopped';
    const { x, y, theta } = this.trajectory;
    const i = this.step;
    const dx = x[i] - x[i - 1];
    const dy = y[i] - y[i - 1];
    const v = Math.sqrt(dx * dx + dy * dy);
    const omega = Math.abs(theta[i] - theta[i - 1]);

    if (v < 0.5 && omega < 0.001) return '⏸ Stopped';
    if (omega > 0.02 && v < 2) return '🔄 Turning in place';
    if (omega > 0.01) return '↩️ Turning while moving';
    return '➡️ Driving straight';
  }
}

<template><MobilePage /></template>
