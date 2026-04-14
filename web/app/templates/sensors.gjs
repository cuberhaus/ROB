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

  data = null;
  encoderCanvas = null;
  laserCanvas = null;
  scanCanvas = null;
  W = 600;
  H = 250;

  @action
  async setup(el) {
    this.encoderCanvas = el.querySelector('#enc-canvas');
    this.laserCanvas = el.querySelector('#laser-canvas');
    this.scanCanvas = el.querySelector('#scan-canvas');

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

  @action
  onScan(e) {
    this.scanIndex = parseInt(e.target.value, 10);
    this.drawScan();
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
      ctx.fillText(`Sensor ${s}`, 5 + s * 65, 12);
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

    // Draw range circles
    ctx.strokeStyle = '#1a1d27';
    ctx.lineWidth = 0.5;
    for (let r = 1000; r <= maxR; r += 1000) {
      ctx.beginPath();
      ctx.arc(W / 2, H / 2, r * scale, 0, Math.PI * 2);
      ctx.stroke();
    }

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
      <p>Time-series encoder and laser plots from real mobile robot data.</p>
    </div>

    <div {{didInsert this.setup}}>
      <div class="grid-2">
        <div class="card">
          <h3 class="card-title">Encoder Angular Speed</h3>
          <div class="canvas-wrap">
            <canvas id="enc-canvas"></canvas>
          </div>
        </div>

        <div class="card">
          <h3 class="card-title">Laser Distance Sensors</h3>
          <div class="canvas-wrap">
            <canvas id="laser-canvas"></canvas>
          </div>
        </div>
      </div>

      <div class="card" style="margin-top:1rem">
        <h3 class="card-title">Laser Scan Viewer</h3>
        <div class="controls">
          <div class="slider-group" style="flex:1">
            <label>Scan</label>
            <input type="range" min="0" max={{this.maxScan}} value={{this.scanIndex}} {{on "input" this.onScan}}>
            <span class="val">{{this.scanIndex}}/{{this.maxScan}}</span>
          </div>
        </div>
        <div class="canvas-wrap" style="max-width:400px;margin:0 auto">
          <canvas id="scan-canvas"></canvas>
        </div>
      </div>
    </div>
  </template>
}

<template><SensorsPage /></template>
