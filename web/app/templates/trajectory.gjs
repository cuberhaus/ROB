import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { on } from '@ember/modifier';
import { didInsert } from '@ember/render-modifiers';
import { ROBOT_CONFIGS, forwardKinematics, getPosition } from '../utils/kinematics';
import { setupCanvas } from '../utils/canvas-helpers';

class TrajectoryPage extends Component {
  @tracked selectedRobot = 'threeLink';
  @tracked waypoints = [
    [0, 0, 0],
    [0, Math.PI / 4, -Math.PI / 4],
    [Math.PI / 2, 0, Math.PI / 4],
    [0, -Math.PI / 4, Math.PI / 3],
  ];
  @tracked progress = 0;
  @tracked interpolation = 'linear';
  @tracked playing = false;

  canvas = null;
  pathCanvas = null;
  animId = null;
  W = 600;
  H = 400;

  get config() {
    return ROBOT_CONFIGS[this.selectedRobot];
  }

  get numJoints() {
    return this.config?.dh?.length ?? 0;
  }

  @action
  setup(el) {
    this.canvas = el.querySelector('#traj-canvas');
    this.pathCanvas = el.querySelector('#path-canvas');
    this.draw();
  }

  @action
  togglePlay() {
    this.playing = !this.playing;
    if (this.playing) this.animate();
    else cancelAnimationFrame(this.animId);
  }

  @action
  onProgress(e) {
    this.progress = parseFloat(e.target.value);
    this.draw();
  }

  animate() {
    if (!this.playing) return;
    this.progress = (this.progress + 0.005) % 1;
    this.draw();
    this.animId = requestAnimationFrame(() => this.animate());
  }

  interpolateJoints(t) {
    const wps = this.waypoints;
    if (wps.length < 2) return wps[0] || new Array(this.numJoints).fill(0);

    const totalSegments = wps.length - 1;
    const segment = Math.min(Math.floor(t * totalSegments), totalSegments - 1);
    const localT = (t * totalSegments) - segment;

    const from = wps[segment];
    const to = wps[segment + 1];

    if (this.interpolation === 'cubic') {
      // Smooth cubic interpolation (ease in-out)
      const s = localT * localT * (3 - 2 * localT);
      return from.map((v, i) => v + (to[i] - v) * s);
    }
    // Linear
    return from.map((v, i) => v + (to[i] - v) * localT);
  }

  draw() {
    if (!this.canvas) return;
    const ctx = setupCanvas(this.canvas, this.W, this.H);

    // Draw joint angle curves over time
    const wps = this.waypoints;
    const n = this.numJoints;
    const colors = ['#4dabf7', '#69db7c', '#ffd43b', '#ff6b6b', '#da77f2', '#20c997'];

    ctx.fillStyle = '#0a0c12';
    ctx.fillRect(0, 0, this.W, this.H);

    // Grid
    ctx.strokeStyle = '#1a1d27';
    ctx.lineWidth = 1;
    for (let y = 0; y <= this.H; y += 50) {
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(this.W, y); ctx.stroke();
    }

    // Joint curves
    const steps = 200;
    for (let j = 0; j < n; j++) {
      ctx.strokeStyle = colors[j % colors.length];
      ctx.lineWidth = 2;
      ctx.beginPath();
      for (let s = 0; s <= steps; s++) {
        const t = s / steps;
        const joints = this.interpolateJoints(t);
        const px = t * this.W;
        const py = this.H / 2 - (joints[j] / Math.PI) * (this.H / 2 - 20);
        s === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
      }
      ctx.stroke();
    }

    // Current position line
    ctx.strokeStyle = '#fff';
    ctx.lineWidth = 1;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    ctx.moveTo(this.progress * this.W, 0);
    ctx.lineTo(this.progress * this.W, this.H);
    ctx.stroke();
    ctx.setLineDash([]);

    // Waypoint markers
    ctx.fillStyle = '#fff';
    for (let i = 0; i < wps.length; i++) {
      const px = (i / (wps.length - 1)) * this.W;
      ctx.beginPath();
      ctx.arc(px, 10, 4, 0, Math.PI * 2);
      ctx.fill();
    }

    // Legend
    ctx.font = '11px Inter, sans-serif';
    for (let j = 0; j < n; j++) {
      ctx.fillStyle = colors[j % colors.length];
      ctx.fillText(`q${j + 1}`, 5, 25 + j * 14);
    }

    // Draw end-effector path
    this.drawPath();
  }

  drawPath() {
    if (!this.pathCanvas || !this.config) return;
    const W = 300, H = 300;
    const ctx = setupCanvas(this.pathCanvas, W, H);

    ctx.fillStyle = '#0a0c12';
    ctx.fillRect(0, 0, W, H);

    // Compute EE path
    const steps = 100;
    const positions = [];
    for (let s = 0; s <= steps; s++) {
      const t = s / steps;
      const joints = this.interpolateJoints(t);
      const { endEffector } = forwardKinematics(this.config.dh, joints);
      positions.push(getPosition(endEffector));
    }

    // Project to 2D (XZ plane)
    const xs = positions.map(p => p[0]);
    const zs = positions.map(p => p[2]);
    const minX = Math.min(...xs), maxX = Math.max(...xs);
    const minZ = Math.min(...zs), maxZ = Math.max(...zs);
    const rangeX = maxX - minX || 1;
    const rangeZ = maxZ - minZ || 1;
    const scale = Math.min((W - 40) / rangeX, (H - 40) / rangeZ);

    ctx.strokeStyle = '#4dabf7';
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let i = 0; i < positions.length; i++) {
      const px = W / 2 + (positions[i][0] - (minX + maxX) / 2) * scale;
      const py = H / 2 - (positions[i][2] - (minZ + maxZ) / 2) * scale;
      i === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
    }
    ctx.stroke();

    // Current EE position
    const curJoints = this.interpolateJoints(this.progress);
    const { endEffector } = forwardKinematics(this.config.dh, curJoints);
    const curPos = getPosition(endEffector);
    const cx = W / 2 + (curPos[0] - (minX + maxX) / 2) * scale;
    const cz = H / 2 - (curPos[2] - (minZ + maxZ) / 2) * scale;
    ctx.fillStyle = '#ff6b6b';
    ctx.beginPath();
    ctx.arc(cx, cz, 5, 0, Math.PI * 2);
    ctx.fill();

    ctx.font = '10px Inter';
    ctx.fillStyle = '#8b8fa3';
    ctx.fillText('End-Effector Path (XZ)', 5, H - 5);
  }

  <template>
    <div class="page-header">
      <h2>📐 Trajectory Planner</h2>
      <p>Joint-space interpolation between waypoints. View joint curves and Cartesian end-effector path.</p>
    </div>

    <div {{this.setup}} class="grid-2">
      <div class="card span-2">
        <div class="controls">
          <button class={{if this.playing "primary" ""}} type="button" {{on "click" this.togglePlay}}>
            {{if this.playing "⏸ Pause" "▶ Play"}}
          </button>
          <div class="slider-group">
            <label>t</label>
            <input type="range" min="0" max="1" step="0.001" value={{this.progress}} {{on "input" this.onProgress}}>
            <span class="val">{{this.progressFmt}}</span>
          </div>
          <label>Interp:</label>
          <select {{on "change" this.onInterp}}>
            <option value="linear">Linear</option>
            <option value="cubic">Cubic</option>
          </select>
        </div>
        <div class="canvas-wrap">
          <canvas id="traj-canvas"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">End-Effector Path</h3>
        <div class="canvas-wrap">
          <canvas id="path-canvas"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">Waypoints ({{this.waypoints.length}})</h3>
        <table class="info-table">
          <thead><tr><th>#</th>{{#each (this.jointHeaders) as |h|}}<th>{{h}}</th>{{/each}}</tr></thead>
          <tbody>
            {{#each this.waypoints as |wp idx|}}
              <tr>
                <td>{{idx}}</td>
                {{#each wp as |val|}}
                  <td>{{this.radToDeg val}}°</td>
                {{/each}}
              </tr>
            {{/each}}
          </tbody>
        </table>
      </div>
    </div>
  </template>

  @action onInterp(e) { this.interpolation = e.target.value; this.draw(); }

  get progressFmt() { return this.progress.toFixed(3); }

  radToDeg = (v) => (v * 180 / Math.PI).toFixed(0);

  jointHeaders = () => {
    const n = this.numJoints;
    return Array.from({ length: n }, (_, i) => `q${i + 1}`);
  };
}

<template><TrajectoryPage /></template>
