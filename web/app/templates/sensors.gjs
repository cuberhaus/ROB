import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { on } from '@ember/modifier';
import { didInsert } from '@ember/render-modifiers';
import { setupCanvas } from '../utils/canvas-helpers';

class SensorsPage extends Component {
  @tracked loaded = false;
  @tracked scanIndex = 0;
  @tracked maxScan = 0;

  @tracked scanPlaying = false;

  data = null;
  encoderCanvas = null;
  laserCanvas = null;
  scanCanvas = null;
  W = 600;
  H = 250;

  resizeObserver = null;

  @action
  async setup(el) {
    this.encoderCanvas = el.querySelector('#enc-canvas');
    this.laserCanvas = el.querySelector('#laser-canvas');
    this.scanCanvas = el.querySelector('#scan-canvas');

    this.resizeObserver = new ResizeObserver(entries => {
      for (let entry of entries) {
        if (entry.target === this.encoderCanvas.parentElement) {
          this.W = entry.contentRect.width;
          if (this.loaded) {
            this.drawEncoder();
            this.drawLaserTimeSeries();
          }
        }
      }
    });
    this.resizeObserver.observe(this.encoderCanvas.parentElement);

    try {
      const [sensRes, laserRes] = await Promise.all([
        fetch('/data/sensors.json'),
        fetch('/data/laser.json'),
      ]);
      this.data = {
        sensors: await sensRes.json(),
        laser: await laserRes.json(),
      };
      this.maxScan = this.data.sensors.polar_laser_data.length - 1;
      this.loaded = true;
      this.drawEncoder();
      this.drawLaserTimeSeries();
      this.drawScan();
    } catch (e) {
      console.error('Failed to load sensor data:', e);
    }
  }

  willDestroy() {
    super.willDestroy?.();
    if (this.resizeObserver) this.resizeObserver.disconnect();
    cancelAnimationFrame(this._scanAnimId);
    if (this._keyHandler) document.removeEventListener('keydown', this._keyHandler);
  }

  @action
  onScan(e) {
    this.scanIndex = parseInt(e.target.value, 10);
    this.drawScan();
    if (this.loaded) {
      this.drawEncoder();
      this.drawLaserTimeSeries();
    }
  }

  _setScan(idx) {
    this.scanIndex = Math.max(0, Math.min(idx, this.maxScan));
    this.drawScan();
    if (this.loaded) { this.drawEncoder(); this.drawLaserTimeSeries(); }
  }

  @action scanFirst() { this._setScan(0); }
  @action scanLast() { this._setScan(this.maxScan); }

  _scanAnimId = null;
  _keyHandler = null;

  @action
  setupScanKeys() {
    this._keyHandler = (e) => {
      if (e.key === 'ArrowLeft') { e.preventDefault(); this._setScan(this.scanIndex - 1); }
      if (e.key === 'ArrowRight') { e.preventDefault(); this._setScan(this.scanIndex + 1); }
    };
    document.addEventListener('keydown', this._keyHandler);
  }

  @action
  toggleScanPlay() {
    this.scanPlaying = !this.scanPlaying;
    if (this.scanPlaying) this._animateScan();
    else cancelAnimationFrame(this._scanAnimId);
  }

  _lastScanFrame = 0;
  _animateScan() {
    if (!this.scanPlaying) return;
    this._scanAnimId = requestAnimationFrame((ts) => {
      if (ts - this._lastScanFrame > 50) {
        this._lastScanFrame = ts;
        if (this.scanIndex >= this.maxScan) {
          this.scanPlaying = false;
          return;
        }
        this._setScan(this.scanIndex + 1);
      }
      this._animateScan();
    });
  }

  drawEncoder() {
    if (!this.encoderCanvas || !this.data) return;
    const ctx = setupCanvas(this.encoderCanvas, this.W, this.H);
    const { left_angular_speed: left, right_angular_speed: right } = this.data.sensors;

    ctx.fillStyle = '#0a0c12';
    ctx.fillRect(0, 0, this.W, this.H);

    const n = left.length;
    const maxT = left[n - 1]?.[0] ?? 1;

    // Find y range
    let minV = Infinity, maxV = -Infinity;
    for (let i = 0; i < n; i++) {
      minV = Math.min(minV, left[i][1], right[i][1]);
      maxV = Math.max(maxV, left[i][1], right[i][1]);
    }
    const range = maxV - minV || 1;

    // Draw left
    ctx.strokeStyle = '#4dabf7';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    for (let i = 0; i < n; i += 5) {
      const px = (left[i][0] / maxT) * this.W;
      const py = this.H - ((left[i][1] - minV) / range) * (this.H - 30) - 15;
      i === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
    }
    ctx.stroke();

    // Draw right
    ctx.strokeStyle = '#69db7c';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    for (let i = 0; i < n; i += 5) {
      const px = (right[i][0] / maxT) * this.W;
      const py = this.H - ((right[i][1] - minV) / range) * (this.H - 30) - 15;
      i === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
    }
    ctx.stroke();

    // Legend
    ctx.font = '11px Inter, sans-serif';
    ctx.fillStyle = '#4dabf7';
    ctx.fillText('Left ω', 5, 12);
    ctx.fillStyle = '#69db7c';
    ctx.fillText('Right ω', 55, 12);

    // Axis labels
    ctx.fillStyle = '#8b8fa3';
    ctx.font = '10px Inter, sans-serif';
    ctx.fillText('Time (s)', this.W / 2 - 20, this.H - 2);
    ctx.save();
    ctx.translate(10, this.H / 2 + 20);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText('ω (rad/s)', 0, 0);
    ctx.restore();

    // Y-axis tick labels
    ctx.fillStyle = '#5c5f73';
    ctx.font = '9px Inter, sans-serif';
    ctx.textAlign = 'left';
    ctx.fillText(maxV.toFixed(1), 2, 25);
    ctx.fillText(minV.toFixed(1), 2, this.H - 18);

    // X-axis tick labels
    ctx.fillText('0', 2, this.H - 5);
    ctx.textAlign = 'right';
    ctx.fillText(maxT.toFixed(1) + 's', this.W - 2, this.H - 5);
    ctx.textAlign = 'left';

    // Playhead
    if (this.maxScan > 0) {
      const playheadPx = (this.scanIndex / this.maxScan) * this.W;
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.4)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(playheadPx, 0);
      ctx.lineTo(playheadPx, this.H);
      ctx.stroke();
    }
  }

  drawLaserTimeSeries() {
    if (!this.laserCanvas || !this.data) return;
    const ctx = setupCanvas(this.laserCanvas, this.W, this.H);
    const { l_s_d } = this.data.laser;

    ctx.fillStyle = '#0a0c12';
    ctx.fillRect(0, 0, this.W, this.H);

    // Plot first 4 laser sensor distances over time
    const colors = ['#4dabf7', '#69db7c', '#ffd43b', '#ff6b6b'];
    const n = l_s_d.length;

    for (let s = 0; s < Math.min(4, l_s_d[0]?.length ?? 0); s++) {
      let minV = Infinity, maxV = -Infinity;
      for (let i = 0; i < n; i++) {
        const v = l_s_d[i][s];
        if (v > 0) { minV = Math.min(minV, v); maxV = Math.max(maxV, v); }
      }
      const range = maxV - minV || 1;

      ctx.strokeStyle = colors[s];
      ctx.lineWidth = 1;
      ctx.beginPath();
      let started = false;
      for (let i = 0; i < n; i += 3) {
        const v = l_s_d[i][s];
        if (v <= 0) continue;
        const px = (i / n) * this.W;
        const py = this.H - ((v - minV) / range) * (this.H - 30) - 15;
        if (!started) { ctx.moveTo(px, py); started = true; } else { ctx.lineTo(px, py); }
      }
      ctx.stroke();
    }

    ctx.font = '11px Inter, sans-serif';
    for (let s = 0; s < Math.min(4, colors.length); s++) {
      ctx.fillStyle = colors[s];
      ctx.fillText(`Beam ${s}`, 5 + s * 55, 12);
    }

    // Axis labels
    ctx.fillStyle = '#8b8fa3';
    ctx.font = '10px Inter, sans-serif';
    ctx.fillText('Scan index', this.W / 2 - 25, this.H - 2);
    ctx.save();
    ctx.translate(10, this.H / 2 + 15);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText('Distance (mm)', 0, 0);
    ctx.restore();

    // Playhead
    if (this.maxScan > 0) {
      const playheadPx = (this.scanIndex / this.maxScan) * this.W;
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.4)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(playheadPx, 0);
      ctx.lineTo(playheadPx, this.H);
      ctx.stroke();
    }
  }

  drawScan() {
    if (!this.scanCanvas || !this.data) return;
    const W = 400, H = 400;
    const ctx = setupCanvas(this.scanCanvas, W, H);

    ctx.fillStyle = '#0a0c12';
    ctx.fillRect(0, 0, W, H);

    const scan = this.data.sensors.polar_laser_data[this.scanIndex];
    if (!scan) return;

    const fov = (240 * Math.PI) / 180;
    const n = scan.length;
    const angleStep = fov / (n - 1);
    const startAngle = -fov / 2;

    // Find max range for scaling
    let maxR = 0;
    for (let i = 0; i < n; i++) {
      if (scan[i] > 0 && scan[i] < 6000) maxR = Math.max(maxR, scan[i]);
    }
    const scale = (H / 2 - 20) / (maxR || 1);

    // Draw range circles with labels
    ctx.strokeStyle = '#1a1d27';
    ctx.lineWidth = 0.5;
    ctx.font = '9px Inter, sans-serif';
    ctx.fillStyle = '#5c5f73';
    for (let r = 1000; r <= maxR; r += 1000) {
      ctx.beginPath();
      ctx.arc(W / 2, H / 2, r * scale, 0, Math.PI * 2);
      ctx.stroke();
      ctx.fillText(`${(r / 1000).toFixed(0)}m`, W / 2 + 3, H / 2 - r * scale + 10);
    }

    // Draw FOV arc to show scanning area
    ctx.strokeStyle = '#333';
    ctx.lineWidth = 0.5;
    ctx.beginPath();
    ctx.moveTo(W / 2, H / 2);
    ctx.arc(W / 2, H / 2, 30, -fov / 2, fov / 2);
    ctx.closePath();
    ctx.stroke();

    // Forward direction indicator
    ctx.strokeStyle = '#ff6b6b';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(W / 2, H / 2);
    ctx.lineTo(W / 2 + 25, H / 2);
    ctx.stroke();
    ctx.fillStyle = '#ff6b6b';
    ctx.font = '9px Inter, sans-serif';
    ctx.fillText('front', W / 2 + 28, H / 2 + 3);

    // Draw scan points
    ctx.fillStyle = '#69db7c';
    for (let i = 0; i < n; i++) {
      if (scan[i] <= 0 || scan[i] > 6000) continue;
      const angle = startAngle + i * angleStep;
      const px = W / 2 + Math.cos(angle) * scan[i] * scale;
      const py = H / 2 - Math.sin(angle) * scan[i] * scale;
      ctx.beginPath();
      ctx.arc(px, py, 1.5, 0, Math.PI * 2);
      ctx.fill();
    }

    // Robot at center
    ctx.fillStyle = '#ff6b6b';
    ctx.beginPath();
    ctx.arc(W / 2, H / 2, 4, 0, Math.PI * 2);
    ctx.fill();

    ctx.font = '10px Inter';
    ctx.fillStyle = '#8b8fa3';
    ctx.fillText(`Scan #${this.scanIndex} (${scan.length} beams)`, 5, H - 5);
  }

  <template>
    <div class="page-header">
      <h2>📊 Sensor Dashboard</h2>
      <p>Recorded data from a real mobile robot: wheel encoders and a 240° laser rangefinder (683 beams).</p>
    </div>

    <div {{didInsert this.setup}}>
      <div class="grid-2">
        <div class="card">
          <h3 class="card-title">Encoder Angular Speed</h3>
          <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">Left and right wheel angular velocities over time.</p>
          <div class="canvas-wrap">
            <canvas id="enc-canvas"></canvas>
          </div>
        </div>

        <div class="card">
          <h3 class="card-title">Laser Distance (4 beams)</h3>
          <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">Distance measured by 4 individual laser beams across all scans.</p>
          <div class="canvas-wrap">
            <canvas id="laser-canvas"></canvas>
          </div>
        </div>
      </div>

      <div class="card" style="margin-top:1rem">
        <h3 class="card-title">Laser Scan Viewer</h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">Top-down polar view of a single 240° laser scan. Each dot is a surface the laser hit. The robot is at the center. Use ◀/▶ arrow keys to step, or press play.</p>
        <div class="controls" {{didInsert this.setupScanKeys}}>
          <button type="button" {{on "click" this.scanFirst}} title="First">⏮</button>
          <button class={{if this.scanPlaying "primary" ""}} type="button" {{on "click" this.toggleScanPlay}}>
            {{if this.scanPlaying "⏸ Pause" "▶ Play"}}
          </button>
          <button type="button" {{on "click" this.scanLast}} title="Last">⏭</button>
          <span class="val">{{this.scanIndex}} / {{this.maxScan}}</span>
        </div>
        <div class="canvas-wrap" style="max-width:400px;margin:0 auto">
          <canvas id="scan-canvas"></canvas>
        </div>
      </div>
    </div>
  </template>
}

<template><SensorsPage /></template>
