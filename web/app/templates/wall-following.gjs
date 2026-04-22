import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { on } from '@ember/modifier';
import { didInsert } from '@ember/render-modifiers';
import { wallFollowingStep, DEFAULTS } from '../utils/wall-following';
import { setupCanvas } from '../utils/canvas-helpers';

// Simple obstacle map for simulation
const DEFAULT_WALLS = [
  // Outer border
  { x1: 50, y1: 50, x2: 750, y2: 50 },
  { x1: 750, y1: 50, x2: 750, y2: 550 },
  { x1: 750, y1: 550, x2: 50, y2: 550 },
  { x1: 50, y1: 550, x2: 50, y2: 50 },
  // Inner obstacles
  { x1: 200, y1: 200, x2: 500, y2: 200 },
  { x1: 500, y1: 200, x2: 500, y2: 350 },
  { x1: 300, y1: 350, x2: 500, y2: 350 },
  { x1: 300, y1: 350, x2: 300, y2: 450 },
];

function raycast(ox, oy, angle, walls, maxDist = 3000) {
  let minDist = maxDist;
  const dx = Math.cos(angle);
  const dy = Math.sin(angle);

  for (const w of walls) {
    const ex = w.x2 - w.x1, ey = w.y2 - w.y1;
    const denom = dx * ey - dy * ex;
    if (Math.abs(denom) < 1e-10) continue;
    const t = ((w.x1 - ox) * ey - (w.y1 - oy) * ex) / denom;
    const u = ((w.x1 - ox) * dy - (w.y1 - oy) * dx) / denom;
    if (t > 0 && u >= 0 && u <= 1 && t < minDist) {
      minDist = t;
    }
  }
  return minDist < maxDist ? minDist : -1;
}

function distToSegmentSquared(x, y, x1, y1, x2, y2) {
  const C = x2 - x1;
  const D = y2 - y1;
  const lenSq = C * C + D * D;
  if (lenSq === 0) {
    const dx = x - x1;
    const dy = y - y1;
    return dx * dx + dy * dy;
  }
  const t = Math.max(0, Math.min(1, ((x - x1) * C + (y - y1) * D) / lenSq));
  const projX = x1 + t * C;
  const projY = y1 + t * D;
  const dx = x - projX;
  const dy = y - projY;
  return dx * dx + dy * dy;
}

function checkCollision(x, y, margin, walls, width, height) {
  if (x <= margin || x >= width - margin || y <= margin || y >= height - margin) {
    return true;
  }
  const marginSq = margin * margin;
  for (const w of walls) {
    // Fast Axis-Aligned Bounding Box (AABB) rejection
    // If the robot's bounding box doesn't overlap the wall's bounding box, skip the expensive math
    const minX = Math.min(w.x1, w.x2) - margin;
    const maxX = Math.max(w.x1, w.x2) + margin;
    if (x < minX || x > maxX) continue;

    const minY = Math.min(w.y1, w.y2) - margin;
    const maxY = Math.max(w.y1, w.y2) + margin;
    if (y < minY || y > maxY) continue;

    // Only do the exact point-to-segment math if we are close to the wall
    if (distToSegmentSquared(x, y, w.x1, w.y1, w.x2, w.y2) < marginSq) {
      return true;
    }
  }
  return false;
}

class WallFollowingPage extends Component {
  @tracked playing = false;
  @tracked robotX = 120;
  @tracked robotY = 300;
  @tracked robotTheta = 0;
  @tracked k1Display = 0;
  @tracked k2Display = 0;
  @tracked k3Display = 0;
  @tracked trail = [];
  @tracked stepCount = 0;
  @tracked mode = 'auto'; // 'auto' = wall-following controller, 'manual' = WASD teleop
  @tracked speed = 1;

  // Tunable controller parameters
  @tracked thLateral = DEFAULTS.thLateral;
  @tracked thCentral = DEFAULTS.thCentral;
  @tracked thDiag = DEFAULTS.thDiag;
  @tracked maxCentral = DEFAULTS.maxCentral;
  @tracked maxDiag = DEFAULTS.maxDiag;
  @tracked maxLateral = DEFAULTS.maxLateral;

  canvas = null;
  walls = DEFAULT_WALLS;
  animId = null;
  W = 800;
  H = 600;
  dt = 0.05; // time step

  // Manual control state
  keys = { forward: false, backward: false, left: false, right: false };
  _keydownHandler = null;
  _keyupHandler = null;

  @action
  setup(el) {
    this.canvas = el.querySelector('#wf-canvas');
    this._keydownHandler = (e) => this.onKeyDown(e);
    this._keyupHandler = (e) => this.onKeyUp(e);
    document.addEventListener('keydown', this._keydownHandler);
    document.addEventListener('keyup', this._keyupHandler);
    this.draw();
  }

  willDestroy() {
    super.willDestroy?.();
    cancelAnimationFrame(this.animId);
    if (this._keydownHandler) document.removeEventListener('keydown', this._keydownHandler);
    if (this._keyupHandler) document.removeEventListener('keyup', this._keyupHandler);
  }

  onKeyDown(e) {
    const key = e.key.toLowerCase();
    if (key === 'w' || key === 'arrowup') { this.keys.forward = true; e.preventDefault(); }
    if (key === 's' || key === 'arrowdown') { this.keys.backward = true; e.preventDefault(); }
    if (key === 'a' || key === 'arrowleft') { this.keys.left = true; e.preventDefault(); }
    if (key === 'd' || key === 'arrowright') { this.keys.right = true; e.preventDefault(); }

    // Auto-start in manual mode when keys pressed
    if (this.mode === 'manual' && !this.playing &&
        (this.keys.forward || this.keys.backward || this.keys.left || this.keys.right)) {
      this.playing = true;
      this.animate();
    }
  }

  onKeyUp(e) {
    const key = e.key.toLowerCase();
    if (key === 'w' || key === 'arrowup') this.keys.forward = false;
    if (key === 's' || key === 'arrowdown') this.keys.backward = false;
    if (key === 'a' || key === 'arrowleft') this.keys.left = false;
    if (key === 'd' || key === 'arrowright') this.keys.right = false;
  }

  @action
  setMode(e) {
    this.mode = e.target.value;
    if (this.playing) {
      this.playing = false;
      cancelAnimationFrame(this.animId);
    }
  }

  @action
  onCanvasClick(e) {
    // Click to place robot
    const rect = this.canvas.getBoundingClientRect();
    const scaleX = this.W / rect.width;
    const scaleY = this.H / rect.height;
    const x = (e.clientX - rect.left) * scaleX;
    const y = (e.clientY - rect.top) * scaleY;
    // Only place if inside bounds
    if (x > 20 && x < this.W - 20 && y > 20 && y < this.H - 20) {
      this.robotX = x;
      this.robotY = y;
      this.trail = [];
      this.stepCount = 0;
      this.draw();
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
    this.robotX = 120;
    this.robotY = 300;
    this.robotTheta = 0;
    this.trail = [];
    this.stepCount = 0;
    this.k1Display = 0;
    this.k2Display = 0;
    this.k3Display = 0;
    this.draw();
  }

  animate() {
    if (!this.playing) return;

    if (this.mode === 'manual') {
      this.manualStep();
    } else {
      this.autoStep();
    }

    this.stepCount = this.stepCount + 1;
    this.draw();
    this.animId = requestAnimationFrame(() => this.animate());
  }

  manualStep() {
    const speed = 2.5;
    const turnDiff = 1.2; // differential applied to each wheel for turning
    let vL = 0, vR = 0;

    if (this.keys.forward) { vL += speed; vR += speed; }
    if (this.keys.backward) { vL -= speed; vR -= speed; }
    if (this.keys.left) { vL -= turnDiff; vR += turnDiff; }
    if (this.keys.right) { vL += turnDiff; vR -= turnDiff; }

    if (vL === 0 && vR === 0) return; // No input, skip

    const S = 40;
    const dTheta = (vL - vR) / (2 * S);
    const dist = (vR + vL) / 2;
    const newTheta = this.robotTheta + dTheta;
    const newX = this.robotX + Math.cos(newTheta) * dist;
    const newY = this.robotY + Math.sin(newTheta) * dist;

    const margin = 15;
    if (!checkCollision(newX, newY, margin, this.walls, this.W, this.H)) {
      this.trail = [...this.trail, { x: this.robotX, y: this.robotY }].slice(-2000);
      this.robotX = newX;
      this.robotY = newY;
      this.robotTheta = newTheta;
    }
  }

  autoStep() {
    // Simulate sensor readings (9 directions around robot)
    const angles = [0, Math.PI/4, Math.PI/2, 3*Math.PI/4, Math.PI,
                    -3*Math.PI/4, -Math.PI/2, -Math.PI/4, 0];
    const readings = angles.map(a =>
      raycast(this.robotX, this.robotY, this.robotTheta + a, this.walls));

    // Wall-following controller
    const scale = 0.15; // 1 pixel = (1/0.15) mm
    // Convert pixel distances to mm for the controller using 1/scale
    const centralDist = readings[0] > -1 ? readings[0] / scale : -1;
    const diagDist = readings[7] > -1 ? readings[7] / scale : -1; // diag left
    const leftDist = readings[6] > -1 ? readings[6] / scale : -1; // left

    const { leftMotor, rightMotor, k1, k2, k3 } = wallFollowingStep(centralDist, diagDist, leftDist, {
      thLateral: this.thLateral,
      thCentral: this.thCentral,
      thDiag: this.thDiag,
      maxCentral: this.maxCentral,
      maxDiag: this.maxDiag,
      maxLateral: this.maxLateral,
    });

    // Differential drive update
    const S = 20; // Half-wheelbase in pixel space
    const vL = leftMotor * scale * this.dt * this.speed;
    const vR = rightMotor * scale * this.dt * this.speed;
    const dTheta = (vL - vR) / (2 * S);
    const dist = (vR + vL) / 2;

    const newTheta = this.robotTheta + dTheta;
    const newX = this.robotX + Math.cos(newTheta) * dist;
    const newY = this.robotY + Math.sin(newTheta) * dist;

    // Collision check
    const margin = 15;
    if (!checkCollision(newX, newY, margin, this.walls, this.W, this.H)) {
      this.trail = [...this.trail, { x: this.robotX, y: this.robotY }].slice(-2000);
      this.robotX = newX;
      this.robotY = newY;
      this.robotTheta = newTheta;
    } else {
      this.robotTheta += 0.1; // Turn away from wall
    }

    this.k1Display = k1;
    this.k2Display = k2;
    this.k3Display = k3;
  }

  draw() {
    if (!this.canvas) return;
    const ctx = setupCanvas(this.canvas, this.W, this.H);

    // Background
    ctx.fillStyle = '#0a0c12';
    ctx.fillRect(0, 0, this.W, this.H);

    // Walls
    ctx.strokeStyle = '#555';
    ctx.lineWidth = 3;
    for (const w of this.walls) {
      ctx.beginPath();
      ctx.moveTo(w.x1, w.y1);
      ctx.lineTo(w.x2, w.y2);
      ctx.stroke();
    }

    // Trail
    if (this.trail.length > 1) {
      ctx.strokeStyle = 'rgba(77,171,247,0.3)';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(this.trail[0].x, this.trail[0].y);
      for (const p of this.trail) {
        ctx.lineTo(p.x, p.y);
      }
      ctx.stroke();
    }

    // Sensor rays
    const angles = [0, Math.PI/4, Math.PI/2, 3*Math.PI/4, Math.PI,
                    -3*Math.PI/4, -Math.PI/2, -Math.PI/4];
    ctx.strokeStyle = 'rgba(105,219,124,0.2)';
    ctx.lineWidth = 0.5;
    for (const a of angles) {
      const d = raycast(this.robotX, this.robotY, this.robotTheta + a, this.walls);
      if (d > 0) {
        ctx.beginPath();
        ctx.moveTo(this.robotX, this.robotY);
        ctx.lineTo(
          this.robotX + Math.cos(this.robotTheta + a) * d,
          this.robotY + Math.sin(this.robotTheta + a) * d,
        );
        ctx.stroke();
      }
    }

    // Robot
    ctx.save();
    ctx.translate(this.robotX, this.robotY);
    ctx.rotate(this.robotTheta);
    ctx.fillStyle = '#ff6b6b';
    ctx.beginPath();
    ctx.moveTo(12, 0);
    ctx.lineTo(-8, 7);
    ctx.lineTo(-8, -7);
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  }

  <template>
    <div class="page-header">
      <h2>🧱 Wall-Following Simulator</h2>
      <p>A reactive wall-following controller for a differential-drive robot. The robot uses three distance sensors to hug the left wall while avoiding obstacles ahead.</p>
    </div>

    <div {{didInsert this.setup}} class="grid-2">
      <div class="card span-2">
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">
          The red triangle is the robot, faint green lines are sensor rays (8 directions), and the blue trail shows where it has been.
          In <strong>Auto</strong> mode, three reactive gains drive the motors:
          <strong>k1</strong> turns right when an obstacle is ahead,
          <strong>k2</strong> keeps a target distance from the left wall,
          <strong>k3</strong> turns left to re-acquire the wall when it's lost.
          In <strong>Manual</strong> mode, use WASD/arrows to drive. Click the canvas to reposition the robot.
        </p>
        <div class="controls">
          <label>Mode:</label>
          <select {{on "change" this.setMode}}>
            <option value="auto" selected>Auto (Controller)</option>
            <option value="manual">Manual (WASD)</option>
          </select>
          {{#if (this.isAuto)}}
            <button class={{if this.playing "primary" ""}} type="button" {{on "click" this.togglePlay}}>
              {{if this.playing "⏸ Pause" "▶ Play"}}
            </button>
          {{else}}
            <span style="color:var(--accent);font-size:0.8rem">🎮 Use W/A/S/D or Arrow Keys to drive</span>
          {{/if}}
          <button type="button" {{on "click" this.reset}}>⏮ Reset</button>
          <div class="slider-group">
            <label>Speed</label>
            <input type="number" min="0.1" max="10" step="0.1" value={{this.speed}} {{on "input" this.onSpeed}}
              style="width:4rem;background:var(--card);border:1px solid var(--border);color:var(--text);padding:2px 4px;border-radius:4px;font-size:0.8rem">
            <span class="val">×</span>
          </div>
          <span style="color:var(--text-dim);font-size:0.8rem">Steps: {{this.stepCount}}</span>
        </div>
        <div class="canvas-wrap">
          <canvas id="wf-canvas" {{on "click" this.onCanvasClick}} style="cursor:crosshair"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">Controller Gains</h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">Live gain values from the reactive controller. Each gain is 0–1; higher means stronger correction.</p>
        <table class="info-table">
          <tr><th>k1 (avoid)</th><td>{{this.k1Fmt}}</td></tr>
          <tr><th>k2 (dist)</th><td>{{this.k2Fmt}}</td></tr>
          <tr><th>k3 (track)</th><td>{{this.k3Fmt}}</td></tr>
        </table>
      </div>

      <div class="card">
        <h3 class="card-title">Parameters
          <button type="button" style="margin-left:0.5rem;font-size:0.7rem" {{on "click" this.resetParams}}>Reset</button>
        </h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">Adjust thresholds and motor speeds to see how the controller behaviour changes.</p>
        <div class="slider-group">
          <label style="min-width:5.5rem">Lateral TH</label>
          <input type="range" min="100" max="800" step="25" value={{this.thLateral}} {{on "input" this.onThLateral}}>
          <span class="val">{{this.thLateral}} mm</span>
        </div>
        <div class="slider-group">
          <label style="min-width:5.5rem">Central TH</label>
          <input type="range" min="200" max="1200" step="25" value={{this.thCentral}} {{on "input" this.onThCentral}}>
          <span class="val">{{this.thCentral}} mm</span>
        </div>
        <div class="slider-group">
          <label style="min-width:5.5rem">Diagonal TH</label>
          <input type="range" min="100" max="1000" step="25" value={{this.thDiag}} {{on "input" this.onThDiag}}>
          <span class="val">{{this.thDiag}} mm</span>
        </div>
        <div class="slider-group">
          <label style="min-width:5.5rem">Max Central</label>
          <input type="range" min="100" max="1500" step="50" value={{this.maxCentral}} {{on "input" this.onMaxCentral}}>
          <span class="val">{{this.maxCentral}}</span>
        </div>
        <div class="slider-group">
          <label style="min-width:5.5rem">Max Diag</label>
          <input type="range" min="50" max="600" step="25" value={{this.maxDiag}} {{on "input" this.onMaxDiag}}>
          <span class="val">{{this.maxDiag}}</span>
        </div>
        <div class="slider-group">
          <label style="min-width:5.5rem">Max Lateral</label>
          <input type="range" min="25" max="400" step="25" value={{this.maxLateral}} {{on "input" this.onMaxLateral}}>
          <span class="val">{{this.maxLateral}}</span>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">Robot Pose</h3>
        <table class="info-table">
          <tr><th>x</th><td>{{this.xFmt}} px</td></tr>
          <tr><th>y</th><td>{{this.yFmt}} px</td></tr>
          <tr><th>θ</th><td>{{this.thetaFmt}}°</td></tr>
        </table>
        {{#unless (this.isAuto)}}
          <div style="margin-top:0.75rem">
            <h4 style="font-size:0.8rem;color:var(--text-dim)">Controls</h4>
            <table class="info-table" style="font-size:0.75rem">
              <tr><td>W / ↑</td><td>Forward</td></tr>
              <tr><td>S / ↓</td><td>Backward</td></tr>
              <tr><td>A / ←</td><td>Turn Left</td></tr>
              <tr><td>D / →</td><td>Turn Right</td></tr>
            </table>
          </div>
        {{/unless}}
      </div>
    </div>
  </template>

  get k1Fmt() { return this.k1Display.toFixed(3); }
  get k2Fmt() { return this.k2Display.toFixed(3); }
  get k3Fmt() { return this.k3Display.toFixed(3); }
  get xFmt() { return this.robotX.toFixed(1); }
  get yFmt() { return this.robotY.toFixed(1); }
  get thetaFmt() { return (this.robotTheta * 180 / Math.PI).toFixed(1); }
  isAuto = () => this.mode === 'auto';

  @action onThLateral(e) { this.thLateral = parseInt(e.target.value); }
  @action onThCentral(e) { this.thCentral = parseInt(e.target.value); }
  @action onThDiag(e) { this.thDiag = parseInt(e.target.value); }
  @action onMaxCentral(e) { this.maxCentral = parseInt(e.target.value); }
  @action onMaxDiag(e) { this.maxDiag = parseInt(e.target.value); }
  @action onMaxLateral(e) { this.maxLateral = parseInt(e.target.value); }

  @action onSpeed(e) { this.speed = parseFloat(e.target.value); }
  get speedFmt() { return this.speed.toFixed(1); }

  @action resetParams() {
    this.thLateral = DEFAULTS.thLateral;
    this.thCentral = DEFAULTS.thCentral;
    this.thDiag = DEFAULTS.thDiag;
    this.maxCentral = DEFAULTS.maxCentral;
    this.maxDiag = DEFAULTS.maxDiag;
    this.maxLateral = DEFAULTS.maxLateral;
  }
}

<template><WallFollowingPage /></template>
