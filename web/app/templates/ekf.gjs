import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { on } from '@ember/modifier';
import { didInsert } from '@ember/render-modifiers';
import { createEKF, ekfPredict, ekfUpdate, getCovarianceEllipse } from '../utils/ekf';
import { buildTrajectory } from '../utils/odometry';
import { setupCanvas, createCamera, applyCamera, drawArrow, drawEllipse } from '../utils/canvas-helpers';

class EkfPage extends Component {
  @tracked step = 0;
  @tracked maxStep = 0;
  @tracked playing = false;
  @tracked loaded = false;
  @tracked speed = 3;

  canvas = null;
  covCanvas = null;
  camera = createCamera(0, 0, 0.08);
  encoder = null;
  landmarks = [];
  ekfHistory = [];
  gtTrajectory = null;
  animId = null;
  W = 700;
  H = 500;

  @action
  async setup(el) {
    this.canvas = el.querySelector('#ekf-canvas');
    this.covCanvas = el.querySelector('#cov-canvas');

    try {
      const [encRes, wpRes] = await Promise.all([
        fetch('/data/encoder.json'),
        fetch('/data/waypoints.json'),
      ]);
      this.encoder = await encRes.json();
      const wp = await wpRes.json();

      // Convert encoder from meters to mm
      this.encoder.L_acu.forEach(p => { p[1] *= 1000; });
      this.encoder.R_acu.forEach(p => { p[1] *= 1000; });

      // The waypoints in the dataset are in grid cell units (resolution = 0.18m/cell)
      // Multiply by 180 to convert to millimeters
      wp.waypoints[0] = wp.waypoints[0].map(v => v * 180);
      wp.waypoints[1] = wp.waypoints[1].map(v => v * 180);

      // Use waypoints as landmarks
      const wpData = wp.waypoints;
      this.landmarks = [];
      for (let i = 0; i < wpData[0].length; i++) {
        this.landmarks.push({ x: wpData[0][i], y: wpData[1][i] });
      }

      const x0 = wpData[0][0];
      const y0 = wpData[1][0];
      const dx = wpData[0][7] - wpData[0][0];
      const dy = wpData[1][7] - wpData[1][0];
      const theta0 = Math.atan2(dy, dx);
      const W = (this.encoder.W || 0.52) * 1000; // wheelbase in mm

      // Ground truth trajectory
      this.gtTrajectory = buildTrajectory(this.encoder.L_acu, this.encoder.R_acu, W, x0, y0, theta0);

      // Run EKF offline
      this.runEKF(W, x0, y0, theta0);

      this.maxStep = this.ekfHistory.length - 1;
      this.loaded = true;

      // Auto-center camera
      const xs = this.gtTrajectory.x;
      const ys = this.gtTrajectory.y;
      const minX = Math.min(...xs), maxX = Math.max(...xs);
      const minY = Math.min(...ys), maxY = Math.max(...ys);
      this.camera.cx = (minX + maxX) / 2;
      this.camera.cy = (minY + maxY) / 2;
      const rangeX = maxX - minX || 1;
      const rangeY = maxY - minY || 1;
      this.camera.scale = Math.min(this.W / rangeX, this.H / rangeY) * 0.7;

      this.draw();
      this.drawCovariance();
    } catch (e) {
      console.error('Failed to load EKF data:', e);
    }
  }

  runEKF(W, x0, y0, theta0) {
    const L = this.encoder.L_acu;
    const R = this.encoder.R_acu;
    const n = Math.min(L.length, R.length);
    const ekf = createEKF(x0, y0, theta0);
    this.ekfHistory = [{ x: [...ekf.x], P: [...ekf.P] }];

    // Process every 10th sample for reasonable step count
    const stride = 10;
    for (let i = stride; i < n; i += stride) {
      const dL = L[i][1] - L[i - stride][1];
      const dR = R[i][1] - R[i - stride][1];

      // Simulate noisy odometry
      // We inject a tiny bit of random noise, but NO systematic slip so the paths stay aligned.
      const noisy_dL = dL + (Math.random() - 0.5) * 5;
      const noisy_dR = dR + (Math.random() - 0.5) * 5;

      // Predict
      ekfPredict(ekf, noisy_dL, noisy_dR, W);

      // We should simulate measurements using the GROUND TRUTH position, not the EKF prediction!
      // Since gtTrajectory has step-by-step points, the index for gtTrajectory is i.
      const gtX = this.gtTrajectory.x[i];
      const gtY = this.gtTrajectory.y[i];

      // Update: find nearest landmark within range
      for (const lm of this.landmarks) {
        const trueDx = lm.x - gtX;
        const trueDy = lm.y - gtY;
        const trueDist = Math.sqrt(trueDx * trueDx + trueDy * trueDy);

        if (trueDist < 4000) {
          // Simulate noisy range measurement
          const noise = (Math.random() - 0.5) * 40; // std dev ~ 11.5 mm
          ekfUpdate(ekf, trueDist + noise, lm.x, lm.y);
        }
      }

      this.ekfHistory.push({ x: [...ekf.x], P: [...ekf.P] });
    }
  }

  @action togglePlay() {
    this.playing = !this.playing;
    if (this.playing) this.animate();
    else cancelAnimationFrame(this.animId);
  }

  @action reset() {
    this.playing = false;
    cancelAnimationFrame(this.animId);
    this.step = 0;
    this.draw();
    this.drawCovariance();
  }

  @action onSlider(e) {
    this.step = parseInt(e.target.value, 10);
    this.draw();
    this.drawCovariance();
  }

  @action onSpeed(e) {
    this.speed = parseInt(e.target.value, 10);
  }

  animate() {
    if (!this.playing) return;
    this.step = Math.min(this.step + this.speed, this.maxStep);
    if (this.step >= this.maxStep) this.playing = false;
    this.draw();
    this.drawCovariance();
    this.animId = requestAnimationFrame(() => this.animate());
  }

  draw() {
    if (!this.canvas || !this.ekfHistory.length) return;
    const ctx = setupCanvas(this.canvas, this.W, this.H);
    const cam = this.camera;
    applyCamera(ctx, cam, this.W, this.H);

    const i = this.step;

    // Draw landmarks
    ctx.fillStyle = 'rgba(255,212,59,0.5)';
    for (const lm of this.landmarks) {
      ctx.beginPath();
      ctx.arc(lm.x, lm.y, 200, 0, Math.PI * 2);
      ctx.fill();
    }

    // Draw ground truth trail
    if (this.gtTrajectory) {
      ctx.strokeStyle = 'rgba(255,255,255,0.15)';
      ctx.lineWidth = 1 / cam.scale;
      ctx.beginPath();
      const stride = 10;
      for (let j = 0; j <= Math.min(i * stride, this.gtTrajectory.x.length - 1); j += stride) {
        j === 0 ? ctx.moveTo(this.gtTrajectory.x[j], this.gtTrajectory.y[j])
                 : ctx.lineTo(this.gtTrajectory.x[j], this.gtTrajectory.y[j]);
      }
      ctx.stroke();
    }

    // Draw EKF estimated trail
    ctx.strokeStyle = '#4dabf7';
    ctx.lineWidth = 2 / cam.scale;
    ctx.beginPath();
    for (let j = 0; j <= i; j++) {
      const s = this.ekfHistory[j];
      j === 0 ? ctx.moveTo(s.x[0], s.x[1]) : ctx.lineTo(s.x[0], s.x[1]);
    }
    ctx.stroke();

    // Draw covariance ellipse at current step
    const curState = this.ekfHistory[i];
    if (curState) {
      const ellipse = getCovarianceEllipse({ x: curState.x, P: curState.P });
      drawEllipse(ctx, ellipse.cx, ellipse.cy, ellipse.rx, ellipse.ry, ellipse.angle);
    }

    // Draw robot
    if (curState) {
      ctx.fillStyle = '#ff6b6b';
      drawArrow(ctx, curState.x[0], curState.x[1], curState.x[2], 80 / cam.scale * 0.3);
    }
  }

  drawCovariance() {
    if (!this.covCanvas || !this.ekfHistory.length) return;
    const W = 300, H = 150;
    const ctx = setupCanvas(this.covCanvas, W, H);

    ctx.fillStyle = '#0a0c12';
    ctx.fillRect(0, 0, W, H);

    const n = Math.min(this.step + 1, this.ekfHistory.length);

    // Plot P[0][0] (x variance) and P[1][1] (y variance) over steps
    const datasets = [
      { idx: 0, color: '#4dabf7', label: 'σ²_x' },
      { idx: 4, color: '#69db7c', label: 'σ²_y' },
      { idx: 8, color: '#ffd43b', label: 'σ²_θ' },
    ];

    for (const ds of datasets) {
      let maxV = 0;
      for (let j = 0; j < n; j++) {
        maxV = Math.max(maxV, Math.abs(this.ekfHistory[j].P[ds.idx]));
      }
      maxV = maxV || 1;

      ctx.strokeStyle = ds.color;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      for (let j = 0; j < n; j++) {
        const px = (j / Math.max(this.maxStep, 1)) * W;
        const py = H - (Math.abs(this.ekfHistory[j].P[ds.idx]) / maxV) * (H - 25) - 10;
        j === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
      }
      ctx.stroke();
    }

    ctx.font = '10px Inter';
    ctx.fillStyle = '#4dabf7'; ctx.fillText('σ²x', 5, 12);
    ctx.fillStyle = '#69db7c'; ctx.fillText('σ²y', 30, 12);
    ctx.fillStyle = '#ffd43b'; ctx.fillText('σ²θ', 55, 12);
  }

  <template>
    <div class="page-header">
      <h2>🎯 EKF Visualizer</h2>
      <p>Extended Kalman Filter fusing noisy wheel odometry with range measurements to known landmarks, producing a smoother position estimate.</p>
    </div>

    <div {{didInsert this.setup}} class="grid-2">
      <div class="card span-2">
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">
          The white trail is the ground-truth trajectory. The blue trail is the EKF's estimated position.
          The red ellipse around the robot shows the current uncertainty (covariance) — a larger ellipse means less certainty about position.
          Yellow circles are fixed landmarks used for range corrections. Watch how the ellipse shrinks when near landmarks.
        </p>
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
            <input type="range" min="1" max="20" value={{this.speed}} {{on "input" this.onSpeed}}>
            <span class="val">×{{this.speed}}</span>
          </div>
        </div>
        <div class="canvas-wrap">
          <canvas id="ekf-canvas"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">EKF State</h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">Current estimated position and heading, plus σ values showing how uncertain each estimate is (lower = more confident).</p>
        {{#if this.loaded}}
          <table class="info-table">
            <tr><th>x̂</th><td>{{this.estX}} mm</td></tr>
            <tr><th>ŷ</th><td>{{this.estY}} mm</td></tr>
            <tr><th>θ̂</th><td>{{this.estTheta}}°</td></tr>
            <tr><th>σ_x</th><td>{{this.sigX}} mm</td></tr>
            <tr><th>σ_y</th><td>{{this.sigY}} mm</td></tr>
          </table>
        {{else}}
          <p>Loading…</p>
        {{/if}}
      </div>

      <div class="card">
        <h3 class="card-title">Covariance over Time</h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">Plots σ²_x, σ²_y, and σ²_θ over time. Uncertainty grows during dead-reckoning and drops after landmark corrections.</p>
        <div class="canvas-wrap">
          <canvas id="cov-canvas"></canvas>
        </div>
      </div>
    </div>
  </template>

  get curState() { return this.ekfHistory[this.step]; }
  get estX() { return this.curState?.x[0]?.toFixed(1) ?? '—'; }
  get estY() { return this.curState?.x[1]?.toFixed(1) ?? '—'; }
  get estTheta() { return ((this.curState?.x[2] ?? 0) * 180 / Math.PI).toFixed(1); }
  get sigX() { return Math.sqrt(Math.abs(this.curState?.P[0] ?? 0)).toFixed(1); }
  get sigY() { return Math.sqrt(Math.abs(this.curState?.P[4] ?? 0)).toFixed(1); }
}

<template><EkfPage /></template>
