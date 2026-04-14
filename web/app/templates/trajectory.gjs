import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
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
  @tracked _wpVersion = 0; // bump to trigger rerender on waypoint mutation
  @tracked progress = 0;
  @tracked interpolation = 'linear';
  @tracked playing = false;
  @tracked draggingWp = -1;

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
      <p>Plan trajectories by editing waypoints. Click values to change, add/remove points, then play to animate.</p>
    </div>

    <div {{didInsert this.setup}} class="grid-2">
      <div class="card span-2">
        <div class="controls">
          <label>Robot:</label>
          <select {{on "change" this.selectRobot}}>
            <option value="threeLink" selected>3-Link 3D</option>
            <option value="puma560">Puma 560 (6-DOF)</option>
          </select>
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
        <p style="font-size:0.75rem;color:var(--text-dim);margin-bottom:0.5rem">Click canvas to add random waypoint</p>
        <div class="canvas-wrap">
          <canvas id="path-canvas" {{on "click" this.onPathClick}} style="cursor:crosshair"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">Waypoints ({{this.waypoints.length}})
          <button type="button" style="margin-left:0.5rem;font-size:0.75rem" {{on "click" this.addWaypoint}}>+ Add</button>
        </h3>
        <table class="info-table">
          <thead><tr><th>#</th>{{#each (this.jointHeaders) as |h|}}<th>{{h}}</th>{{/each}}<th></th></tr></thead>
          <tbody>
            {{#each this.waypoints as |wp idx|}}
              <tr>
                <td>{{idx}}</td>
                {{#each wp as |val jIdx|}}
                  <td>
                    <input type="number" min="-180" max="180" step="5"
                      value={{this.wpJointDeg idx jIdx}}
                      {{on "change" (fn this.onWaypointJoint idx jIdx)}}
                      style="width:3.5rem;background:var(--card);border:1px solid var(--border);color:var(--text);padding:2px 4px;border-radius:4px;font-size:0.75rem"
                    >
                  </td>
                {{/each}}
                <td>
                  <button type="button" {{on "click" (fn this.removeWaypoint idx)}}
                    style="font-size:0.7rem;color:var(--danger,#ff6b6b);background:none;border:none;cursor:pointer"
                    title="Remove waypoint">✕</button>
                </td>
              </tr>
            {{/each}}
          </tbody>
        </table>
      </div>
    </div>
  </template>

  @action onInterp(e) { this.interpolation = e.target.value; this.draw(); }

  @action
  onWaypointJoint(wpIdx, jIdx, e) {
    const deg = parseFloat(e.target.value);
    if (isNaN(deg)) return;
    const rad = (deg * Math.PI) / 180;
    const newWps = this.waypoints.map(wp => [...wp]);
    newWps[wpIdx][jIdx] = rad;
    this.waypoints = newWps;
    this._wpVersion++;
    this.draw();
  }

  @action
  addWaypoint() {
    const n = this.numJoints;
    // Clone last waypoint or use zeros
    const last = this.waypoints.length > 0
      ? [...this.waypoints[this.waypoints.length - 1]]
      : new Array(n).fill(0);
    this.waypoints = [...this.waypoints, last];
    this._wpVersion++;
    this.draw();
  }

  @action
  removeWaypoint(idx) {
    if (this.waypoints.length <= 2) return; // need at least 2
    this.waypoints = this.waypoints.filter((_, i) => i !== idx);
    this._wpVersion++;
    this.draw();
  }

  @action
  selectRobot(e) {
    this.selectedRobot = e.target.value;
    const n = this.numJoints;
    this.waypoints = [
      new Array(n).fill(0),
      new Array(n).fill(Math.PI / 4),
    ];
    this._wpVersion++;
    this.draw();
  }

  @action
  onPathClick(e) {
    // Click on end-effector path canvas to add a waypoint by clicking
    // We'll use IK-like heuristic: randomly perturb last waypoint
    // This is a convenience — real IK would need a solver
    const n = this.numJoints;
    const last = this.waypoints.length > 0
      ? this.waypoints[this.waypoints.length - 1]
      : new Array(n).fill(0);
    const newWp = last.map(v => v + (Math.random() - 0.5) * 0.5);
    this.waypoints = [...this.waypoints, newWp];
    this._wpVersion++;
    this.draw();
  }

  get progressFmt() { return this.progress.toFixed(3); }

  wpJointDeg = (wpIdx, jIdx) => {
    void this._wpVersion; // depend on version
    const wp = this.waypoints[wpIdx];
    return wp ? Math.round((wp[jIdx] ?? 0) * 180 / Math.PI) : 0;
  };

  radToDeg = (v) => (v * 180 / Math.PI).toFixed(0);

  jointHeaders = () => {
    const n = this.numJoints;
    return Array.from({ length: n }, (_, i) => `q${i + 1}`);
  };
}

<template><TrajectoryPage /></template>
