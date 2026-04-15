import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { on } from '@ember/modifier';
import { didInsert } from '@ember/render-modifiers';
import { wallFollowingStep } from '../utils/wall-following';
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
    const dTheta = (vR - vL) / (2 * S);
    const dist = (vR + vL) / 2;
    const newTheta = this.robotTheta + dTheta;
    const newX = this.robotX + Math.cos(newTheta) * dist;
    const newY = this.robotY + Math.sin(newTheta) * dist;

    const margin = 15;
    if (newX > margin && newX < this.W - margin && newY > margin && newY < this.H - margin) {
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
    const centralDist = readings[0];
    const diagDist = readings[7]; // diag left
    const leftDist = readings[6]; // left

    const { leftMotor, rightMotor, k1, k2, k3 } = wallFollowingStep(centralDist, diagDist, leftDist);

    // Differential drive update
    const S = 121.5;
    const scale = 0.15; // Scale motor commands to pixel movement
    const vL = leftMotor * scale * this.dt;
    const vR = rightMotor * scale * this.dt;
    const dTheta = (vR - vL) / (2 * S) * 80; // Amplify rotation for visibility
    const dist = (vR + vL) / 2;

    const newTheta = this.robotTheta + dTheta;
    const newX = this.robotX + Math.cos(newTheta) * dist;
    const newY = this.robotY + Math.sin(newTheta) * dist;

    // Collision check
    const margin = 15;
    if (newX > margin && newX < this.W - margin && newY > margin && newY < this.H - margin) {
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
      <p>Switch to Manual mode and drive with WASD/arrows. Click the canvas to place the robot. Auto mode runs the reactive controller.</p>
    </div>

    <div {{didInsert this.setup}} class="grid-2">
      <div class="card span-2">
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
          <span style="color:var(--text-dim);font-size:0.8rem">Steps: {{this.stepCount}}</span>
        </div>
        <div class="canvas-wrap">
          <canvas id="wf-canvas" {{on "click" this.onCanvasClick}} style="cursor:crosshair"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">Controller Gains</h3>
        <table class="info-table">
          <tr><th>k1 (avoid)</th><td>{{this.k1Fmt}}</td></tr>
          <tr><th>k2 (dist)</th><td>{{this.k2Fmt}}</td></tr>
          <tr><th>k3 (track)</th><td>{{this.k3Fmt}}</td></tr>
        </table>
        <div style="margin-top:0.75rem">
          <h4 style="font-size:0.8rem;color:var(--text-dim)">Thresholds</h4>
          <table class="info-table">
            <tr><td>Lateral</td><td>375 mm</td></tr>
            <tr><td>Central</td><td>675 mm</td></tr>
            <tr><td>Diagonal</td><td>525 mm</td></tr>
          </table>
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
}

<template><WallFollowingPage /></template>
