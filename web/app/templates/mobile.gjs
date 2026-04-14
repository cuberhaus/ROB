import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { on } from '@ember/modifier';
import { didInsert } from '@ember/render-modifiers';
import { buildTrajectory, laserToCartesian, transformPoints } from '../utils/odometry';
import { setupCanvas, createCamera, applyCamera, drawArrow } from '../utils/canvas-helpers';

class MobilePage extends Component {
  @tracked playing = false;
  @tracked step = 0;
  @tracked maxStep = 0;
  @tracked loaded = false;
  @tracked speed = 5;

  canvas = null;
  trajCanvas = null;
  camera = createCamera(0, 0, 0.08);
  trajectory = null;
  sensorData = null;
  animId = null;
  W = 700;
  H = 500;

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
      const [encRes, sensRes, wpRes] = await Promise.all([
        fetch('/data/encoder.json'),
        fetch('/data/sensors.json'),
        fetch('/data/waypoints.json'),
      ]);
      const enc = await encRes.json();
      const sens = await sensRes.json();
      const wp = await wpRes.json();

      this.trajectory = buildTrajectory(enc.L_acu, enc.R_acu);
      this.sensorData = sens;
      this.waypoints = wp.waypoints;
      this.maxStep = this.trajectory.x.length - 1;
      this.loaded = true;

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
    } catch (e) {
      console.error('Failed to load data:', e);
    }
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
    this.draw();
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

    // Draw waypoints
    if (this.waypoints) {
      ctx.fillStyle = 'rgba(255,212,59,0.6)';
      const wp = this.waypoints;
      for (let j = 0; j < wp[0].length; j++) {
        ctx.beginPath();
        ctx.arc(wp[0][j], wp[1][j], 30, 0, Math.PI * 2);
        ctx.fill();
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
        ctx.fillStyle = 'rgba(105,219,124,0.4)';
        for (let j = 0; j < wx.length; j++) {
          ctx.beginPath();
          ctx.arc(wx[j], wy[j], 8, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    }

    // Draw robot
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
      <p>Replay real encoder &amp; laser data. Drag to pan, scroll to zoom. Differential-drive odometry (axle W=243mm).</p>
    </div>

    <div {{didInsert this.setup}} class="grid-2">
      <div class="card span-2">
        <div class="controls">
          <button class={{if this.playing "primary" ""}} type="button" {{on "click" this.togglePlay}}>
            {{if this.playing "⏸ Pause" "▶ Play"}}
          </button>
          <button type="button" {{on "click" this.reset}}>⏮ Reset</button>
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
        </div>
        <div class="canvas-wrap">
          <canvas id="mobile-canvas"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">Pose</h3>
        {{#if this.loaded}}
          <table class="info-table">
            <tr><th>x</th><td>{{this.posX}} mm</td></tr>
            <tr><th>y</th><td>{{this.posY}} mm</td></tr>
            <tr><th>θ</th><td>{{this.posTheta}}°</td></tr>
            <tr><th>Time</th><td>{{this.posTime}} s</td></tr>
          </table>
        {{else}}
          <p>Loading data…</p>
        {{/if}}
      </div>

      <div class="card">
        <h3 class="card-title">Position over Time</h3>
        <div class="canvas-wrap">
          <canvas id="traj-canvas"></canvas>
        </div>
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
}

<template><MobilePage /></template>
