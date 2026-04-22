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
  @tracked speed = 1;
  @tracked draggingWp = -1;

  canvas = null;
  pathCanvas = null;
  babylonCanvas = null;
  animId = null;
  W = 600;
  H = 400;

  // Babylon.js state
  babylonEngine = null;
  babylonScene = null;
  BABYLON = null;
  jointMeshes = [];
  linkMeshes = [];
  trailLine = null;
  _trailVersion = -1;

  get config() {
    return ROBOT_CONFIGS[this.selectedRobot];
  }

  get numJoints() {
    return this.config?.dh?.length ?? 0;
  }

  @action
  async setup(el) {
    this.canvas = el.querySelector('#traj-canvas');
    this.pathCanvas = el.querySelector('#path-canvas');
    this.babylonCanvas = el.querySelector('#traj-3d-canvas');
    if (this.babylonCanvas) await this.initBabylon();
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
    this.progress = (this.progress + 0.005 * this.speed) % 1;
    this.draw();
    this.animId = requestAnimationFrame(() => this.animate());
  }

  // ── Babylon.js 3D ──────────────────────────────────────────

  async initBabylon() {
    try {
      const B = await import('@babylonjs/core');
      this.BABYLON = B;

      const engine = new B.Engine(this.babylonCanvas, true, { preserveDrawingBuffer: true });
      const scene = new B.Scene(engine);
      scene.clearColor = new B.Color4(0.06, 0.07, 0.09, 1);

      const camera = new B.ArcRotateCamera('cam', -Math.PI / 4, Math.PI / 3, 8,
        B.Vector3.Zero(), scene);
      camera.attachControl(this.babylonCanvas, true);
      camera.wheelPrecision = 30;

      new B.HemisphericLight('light', new B.Vector3(0, 1, 0.3), scene);

      this.babylonEngine = engine;
      this.babylonScene = scene;

      this._rebuildSceneForRobot();

      engine.runRenderLoop(() => scene.render());
      const resizeObs = new ResizeObserver(() => engine.resize());
      resizeObs.observe(this.babylonCanvas);
    } catch (e) {
      console.error('Trajectory 3D init failed:', e);
    }
  }

  /** Compute arm reach from DH params to scale the scene properly. */
  _armReach() {
    const dh = this.config?.dh;
    if (!dh) return 1;
    let reach = 0;
    for (const link of dh) reach += Math.abs(link.a) + Math.abs(link.d);
    return Math.max(reach, 0.1);
  }

  /** Re-create ground, base, arm meshes and camera framing for current robot. */
  _rebuildSceneForRobot() {
    const B = this.BABYLON;
    const scene = this.babylonScene;
    if (!B || !scene) return;

    // Dispose old static meshes
    for (const name of ['ground', 'base']) {
      const m = scene.getMeshByName(name);
      if (m) m.dispose();
    }
    for (const mat of ['gMat', 'baseMat']) {
      const m = scene.getMaterialByName(mat);
      if (m) m.dispose();
    }

    const reach = this._armReach();

    // Ground grid scaled to robot
    const gridSize = reach * 3;
    const ground = B.MeshBuilder.CreateGround('ground', { width: gridSize, height: gridSize }, scene);
    const gMat = new B.StandardMaterial('gMat', scene);
    gMat.diffuseColor = new B.Color3(0.1, 0.1, 0.12);
    gMat.wireframe = true;
    ground.material = gMat;

    // Base scaled to robot
    const baseH = reach * 0.03;
    const baseDiam = reach * 0.06;
    const base = B.MeshBuilder.CreateCylinder('base', { height: baseH, diameter: baseDiam }, scene);
    const baseMat = new B.StandardMaterial('baseMat', scene);
    baseMat.diffuseColor = new B.Color3(0.3, 0.3, 0.35);
    base.material = baseMat;
    base.position.y = baseH / 2;

    this.createArmMeshes();
    this._frameCameraOnArm();
    this.updateTrailLine();
  }

  /** Point camera at the arm's center and set radius to frame the workspace. */
  _frameCameraOnArm() {
    const B = this.BABYLON;
    if (!B || !this.babylonScene || !this.config) return;

    // Sample FK across joint space to find 3D bounding box in Babylon coords
    const dh = this.config.dh;
    const n = dh.length;
    let minB = [Infinity, Infinity, Infinity];
    let maxB = [-Infinity, -Infinity, -Infinity];

    const sampleAngles = [-Math.PI, -Math.PI / 2, 0, Math.PI / 2, Math.PI];
    const recurse = (joints) => {
      if (joints.length === n) {
        const pos = getPosition(forwardKinematics(dh, joints).endEffector);
        // Babylon coords: (FK_x, FK_z, FK_y)
        const bp = [pos[0], pos[2], pos[1]];
        for (let k = 0; k < 3; k++) {
          minB[k] = Math.min(minB[k], bp[k]);
          maxB[k] = Math.max(maxB[k], bp[k]);
        }
        return;
      }
      for (const v of sampleAngles) recurse([...joints, v]);
    };
    recurse([]);

    // Also include origin (base position)
    for (let k = 0; k < 3; k++) {
      minB[k] = Math.min(minB[k], 0);
      maxB[k] = Math.max(maxB[k], 0);
    }

    const center = new B.Vector3(
      (minB[0] + maxB[0]) / 2,
      (minB[1] + maxB[1]) / 2,
      (minB[2] + maxB[2]) / 2,
    );
    const extent = Math.max(maxB[0] - minB[0], maxB[1] - minB[1], maxB[2] - minB[2], 0.1);

    const camera = this.babylonScene.activeCamera;
    camera.target = center;
    camera.radius = extent * 1.5;
  }

  createArmMeshes() {
    const B = this.BABYLON;
    const scene = this.babylonScene;
    if (!B || !scene) return;

    for (const m of this.jointMeshes) m.dispose();
    for (const m of this.linkMeshes) m.dispose();
    this.jointMeshes = [];
    this.linkMeshes = [];

    const reach = this._armReach();
    const n = this.numJoints;

    const jointMat = new B.StandardMaterial('jMat', scene);
    jointMat.diffuseColor = new B.Color3(0.3, 0.67, 0.93);
    const linkMat = new B.StandardMaterial('lMat', scene);
    linkMat.diffuseColor = new B.Color3(0.8, 0.8, 0.85);
    const eeMat = new B.StandardMaterial('eeMat', scene);
    eeMat.diffuseColor = new B.Color3(1, 0.42, 0.42);

    const jointDiam = reach * 0.04;
    const linkDiam = reach * 0.015;

    for (let i = 0; i < n; i++) {
      const joint = B.MeshBuilder.CreateSphere(`j${i}`, { diameter: jointDiam }, scene);
      joint.material = jointMat;
      this.jointMeshes.push(joint);

      const link = B.MeshBuilder.CreateCylinder(`l${i}`, { height: 1, diameter: linkDiam }, scene);
      link.material = linkMat;
      this.linkMeshes.push(link);
    }

    const ee = B.MeshBuilder.CreateSphere('ee', { diameter: jointDiam * 0.8 }, scene);
    ee.material = eeMat;
    this.jointMeshes.push(ee);
  }

  updateArm3D() {
    const B = this.BABYLON;
    if (!B || !this.babylonScene || !this.config) return;

    const dh = this.config.dh;
    const curJoints = this.interpolateJoints(this.progress);
    const { transforms } = forwardKinematics(dh, curJoints);

    let prevPos = new B.Vector3(0, 0, 0);

    for (let i = 0; i < transforms.length; i++) {
      const T = transforms[i];
      const pos = new B.Vector3(T[12], T[14], T[13]); // Swap Y/Z for Babylon

      if (this.jointMeshes[i]) {
        this.jointMeshes[i].position = pos;
      }

      if (this.linkMeshes[i]) {
        const mid = B.Vector3.Lerp(prevPos, pos, 0.5);
        this.linkMeshes[i].position = mid;
        const dir = pos.subtract(prevPos);
        const len = dir.length();
        this.linkMeshes[i].scaling = new B.Vector3(1, Math.max(len, 0.01), 1);

        if (len > 0.001) {
          const up = new B.Vector3(0, 1, 0);
          const dirN = dir.normalize();
          const axis = B.Vector3.Cross(up, dirN);
          if (axis.length() > 0.001) {
            const dot = Math.max(-1, Math.min(1, B.Vector3.Dot(up, dirN)));
            this.linkMeshes[i].rotationQuaternion = B.Quaternion.RotationAxis(axis.normalize(), Math.acos(dot));
          } else {
            if (B.Vector3.Dot(up, dirN) < 0) {
              this.linkMeshes[i].rotationQuaternion = B.Quaternion.RotationAxis(new B.Vector3(1, 0, 0), Math.PI);
            } else {
              this.linkMeshes[i].rotationQuaternion = B.Quaternion.Identity();
            }
          }
        } else {
          this.linkMeshes[i].rotationQuaternion = B.Quaternion.Identity();
        }
      }

      prevPos = pos;
    }

    // End effector
    const eeIdx = this.jointMeshes.length - 1;
    if (this.jointMeshes[eeIdx]) {
      const T = transforms[transforms.length - 1];
      this.jointMeshes[eeIdx].position = new B.Vector3(T[12], T[14], T[13]);
    }
  }

  updateTrailLine() {
    const B = this.BABYLON;
    if (!B || !this.babylonScene || !this.config) return;

    if (this.trailLine) { this.trailLine.dispose(); this.trailLine = null; }

    const steps = 100;
    const points = [];
    for (let s = 0; s <= steps; s++) {
      const t = s / steps;
      const joints = this.interpolateJoints(t);
      const { endEffector } = forwardKinematics(this.config.dh, joints);
      const p = getPosition(endEffector);
      points.push(new B.Vector3(p[0], p[2], p[1])); // Swap Y/Z for Babylon
    }

    this.trailLine = B.MeshBuilder.CreateLines('trail', { points }, this.babylonScene);
    this.trailLine.color = new B.Color3(0.3, 0.67, 0.93);
  }

  // ── 2D Drawing ─────────────────────────────────────────────

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
    if (this._trailVersion !== this._wpVersion) {
      this._trailVersion = this._wpVersion;
      this.updateTrailLine();
    }
    this.updateArm3D();
  }

  // Store last projection params so clicks can be un-projected
  _pathProj = null;

  /** Compute stable workspace bounds from robot reach (once per robot change). */
  _computeWorkspaceBounds() {
    if (!this.config) return;
    const dh = this.config.dh;
    // Sample FK at many joint configs to estimate workspace extent in XZ
    const samples = [];
    const n = dh.length;
    const vals = [-Math.PI, -Math.PI / 2, 0, Math.PI / 2, Math.PI];
    const recurse = (joints) => {
      if (joints.length === n) {
        const pos = getPosition(forwardKinematics(dh, joints).endEffector);
        samples.push(pos);
        return;
      }
      for (const v of vals) recurse([...joints, v]);
    };
    recurse([]);
    let minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity;
    for (const p of samples) {
      minX = Math.min(minX, p[0]); maxX = Math.max(maxX, p[0]);
      minZ = Math.min(minZ, p[2]); maxZ = Math.max(maxZ, p[2]);
    }
    // Add 10% padding
    const padX = (maxX - minX) * 0.1 || 1;
    const padZ = (maxZ - minZ) * 0.1 || 1;
    this._wsBounds = { minX: minX - padX, maxX: maxX + padX, minZ: minZ - padZ, maxZ: maxZ + padZ };
  }

  _wsBounds = null;
  _clickTarget = null;

  drawPath() {
    if (!this.pathCanvas || !this.config) return;
    // Use the actual rendered canvas size so coordinate mapping matches clicks
    const rect = this.pathCanvas.getBoundingClientRect();
    const W = Math.round(rect.width) || 300;
    const H = Math.round(rect.height) || 300;
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

    // Project to 2D (XZ plane) using stable workspace bounds
    if (!this._wsBounds) this._computeWorkspaceBounds();
    const { minX, maxX, minZ, maxZ } = this._wsBounds;
    const rangeX = maxX - minX || 1;
    const rangeZ = maxZ - minZ || 1;
    const scale = Math.min((W - 40) / rangeX, (H - 40) / rangeZ);
    const centerX = (minX + maxX) / 2;
    const centerZ = (minZ + maxZ) / 2;

    // Save projection for click→world inversion
    this._pathProj = { W, H, scale, centerX, centerZ };

    // Grid lines for reference
    ctx.strokeStyle = '#1a1d27';
    ctx.lineWidth = 0.5;
    const gridStep = Math.pow(10, Math.floor(Math.log10(rangeX)));
    for (let gx = Math.ceil(minX / gridStep) * gridStep; gx <= maxX; gx += gridStep) {
      const px = W / 2 + (gx - centerX) * scale;
      ctx.beginPath(); ctx.moveTo(px, 0); ctx.lineTo(px, H); ctx.stroke();
    }
    for (let gz = Math.ceil(minZ / gridStep) * gridStep; gz <= maxZ; gz += gridStep) {
      const py = H / 2 - (gz - centerZ) * scale;
      ctx.beginPath(); ctx.moveTo(0, py); ctx.lineTo(W, py); ctx.stroke();
    }

    // EE path curve
    ctx.strokeStyle = '#4dabf7';
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let i = 0; i < positions.length; i++) {
      const px = W / 2 + (positions[i][0] - centerX) * scale;
      const py = H / 2 - (positions[i][2] - centerZ) * scale;
      i === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
    }
    ctx.stroke();

    // Waypoint markers on path
    const wps = this.waypoints;
    for (let i = 0; i < wps.length; i++) {
      const { endEffector: wpEE } = forwardKinematics(this.config.dh, wps[i]);
      const wpPos = getPosition(wpEE);
      const wpx = W / 2 + (wpPos[0] - centerX) * scale;
      const wpy = H / 2 - (wpPos[2] - centerZ) * scale;
      ctx.fillStyle = '#ffd43b';
      ctx.beginPath();
      ctx.arc(wpx, wpy, 4, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = '#ffd43b';
      ctx.font = '9px Inter';
      ctx.fillText(`${i}`, wpx + 6, wpy - 4);
    }

    // Current EE position
    const curJoints = this.interpolateJoints(this.progress);
    const { endEffector } = forwardKinematics(this.config.dh, curJoints);
    const curPos = getPosition(endEffector);
    const cx = W / 2 + (curPos[0] - centerX) * scale;
    const cz = H / 2 - (curPos[2] - centerZ) * scale;
    ctx.fillStyle = '#ff6b6b';
    ctx.beginPath();
    ctx.arc(cx, cz, 5, 0, Math.PI * 2);
    ctx.fill();

    ctx.font = '10px Inter';
    ctx.fillStyle = '#8b8fa3';
    ctx.fillText('End-Effector Path (XZ)', 5, H - 5);

    // Click target crosshair (shows where IK was aiming)
    if (this._clickTarget) {
      const tx = W / 2 + (this._clickTarget.x - centerX) * scale;
      const tz = H / 2 - (this._clickTarget.z - centerZ) * scale;
      ctx.strokeStyle = 'rgba(255,255,255,0.4)';
      ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(tx - 8, tz); ctx.lineTo(tx + 8, tz); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(tx, tz - 8); ctx.lineTo(tx, tz + 8); ctx.stroke();
    }
  }

  <template>
    <div class="page-header">
      <h2>📐 Trajectory Planner</h2>
      <p>Plan a robot arm trajectory by defining waypoints in joint space. The arm interpolates between them to trace a smooth path.</p>
    </div>

    <div {{didInsert this.setup}} class="grid-2">
      <div class="card span-2">
        <h3 class="card-title">Joint Angle Curves</h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">
          Each colored line is one joint angle (q1, q2, …) plotted over normalized time t∈[0,1].
          White dots along the top mark waypoint positions. The dashed vertical line shows the current playback time.
        </p>
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
          <div class="slider-group">
            <label>Speed</label>
            <input type="range" min="0.1" max="5" step="0.1" value={{this.speed}} {{on "input" this.onSpeed}}>
            <span class="val">{{this.speedFmt}}×</span>
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
        <h3 class="card-title">End-Effector Path (top-down XZ)</h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin-bottom:0.5rem">
          Shows where the robot's tip moves in the XZ plane. The blue curve is the full path,
          yellow dots are waypoints, and the red dot is the current position.
          Click anywhere to add a new waypoint — inverse kinematics solves the joint angles automatically.
        </p>
        <div class="canvas-wrap">
          <canvas id="path-canvas" {{on "click" this.onPathClick}} style="cursor:crosshair"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">3D View</h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin-bottom:0.5rem">
          Real-time 3D view of the robot arm at the current playback position.
          The blue trail shows the full end-effector path. Drag to orbit, scroll to zoom.
        </p>
        <div class="canvas-wrap" style="height:350px">
          <canvas id="traj-3d-canvas" style="width:100%;height:100%"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">Waypoints ({{this.waypoints.length}})
          <button type="button" style="margin-left:0.5rem;font-size:0.75rem" {{on "click" this.addWaypoint}}>+ Add</button>
        </h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">
          Each row is a waypoint with joint angles in degrees. Edit values directly or click the path canvas to add via IK.
          The arm moves through these waypoints in order from t=0 to t=1.
        </p>
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

  @action onInterp(e) { this.interpolation = e.target.value; this._wpVersion++; this.draw(); }

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
    this._wsBounds = null; // recompute workspace bounds for new robot
    this._wpVersion++;
    this._rebuildSceneForRobot();
    this.draw();
  }

  @action
  onPathClick(e) {
    if (!this._pathProj || !this.config) return;
    const { W, H, scale, centerX, centerZ } = this._pathProj;

    // Convert click pixel → logical canvas coords → world XZ
    const rect = this.pathCanvas.getBoundingClientRect();
    const px = (e.clientX - rect.left) / rect.width * W;
    const py = (e.clientY - rect.top) / rect.height * H;
    const targetX = (px - W / 2) / scale + centerX;
    const targetZ = -(py - H / 2) / scale + centerZ;

    // Save click target so drawPath can show it
    this._clickTarget = { x: targetX, z: targetZ };

    // Damped least-squares IK with multiple restarts to avoid local minima
    const n = this.numJoints;
    const dh = this.config.dh;
    const last = this.waypoints.length > 0
      ? [...this.waypoints[this.waypoints.length - 1]]
      : new Array(n).fill(0);

    const solveIK = (qInit) => {
      const q = [...qInit];
      const maxIter = 500;
      const lambda = 0.05;
      let finalErr = Infinity;

      for (let iter = 0; iter < maxIter; iter++) {
        const pos = getPosition(forwardKinematics(dh, q).endEffector);
        const errX = targetX - pos[0];
        const errZ = targetZ - pos[2];
        finalErr = errX * errX + errZ * errZ;
        if (finalErr < 1e-6) break;

        // Compute Jacobian (2 x n)
        const J = [];
        for (let j = 0; j < n; j++) {
          const qp = [...q];
          qp[j] += 1e-4;
          const pp = getPosition(forwardKinematics(dh, qp).endEffector);
          J.push({ dx: (pp[0] - pos[0]) / 1e-4, dz: (pp[2] - pos[2]) / 1e-4 });
        }

        // Damped pseudo-inverse: dq = J^T (J J^T + λ²I)^{-1} e
        let a = 0, b = 0, d = 0;
        for (let j = 0; j < n; j++) {
          a += J[j].dx * J[j].dx;
          b += J[j].dx * J[j].dz;
          d += J[j].dz * J[j].dz;
        }
        a += lambda * lambda;
        d += lambda * lambda;
        const det = a * d - b * b;
        if (Math.abs(det) < 1e-12) {
          // Singular — perturb joints randomly to escape
          for (let j = 0; j < n; j++) q[j] += (Math.random() - 0.5) * 0.2;
          continue;
        }
        const vx = (d * errX - b * errZ) / det;
        const vz = (-b * errX + a * errZ) / det;
        for (let j = 0; j < n; j++) {
          q[j] += J[j].dx * vx + J[j].dz * vz;
          q[j] = Math.max(-Math.PI, Math.min(Math.PI, q[j]));
        }
      }
      return { q, err: finalErr };
    };

    // Try from last waypoint + several random starts, keep best
    const candidates = [last];
    for (let r = 0; r < 8; r++) {
      candidates.push(Array.from({ length: n }, () => (Math.random() - 0.5) * 2 * Math.PI));
    }

    let bestQ = last;
    let bestErr = Infinity;
    for (const init of candidates) {
      const { q: sol, err } = solveIK(init);
      if (err < bestErr) {
        bestErr = err;
        bestQ = sol;
        if (err < 1e-6) break; // good enough
      }
    }

    this.waypoints = [...this.waypoints, bestQ];
    this._wpVersion++;
    this.draw();
  }

  get progressFmt() { return this.progress.toFixed(3); }
  get speedFmt() { return this.speed.toFixed(1); }

  @action onSpeed(e) { this.speed = parseFloat(e.target.value); }

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
