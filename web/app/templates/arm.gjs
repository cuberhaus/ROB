import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import { didInsert } from '@ember/render-modifiers';
import { ROBOT_CONFIGS, forwardKinematics, getPosition } from '../utils/kinematics';

class ArmPage extends Component {
  @tracked selectedRobot = 'puma560';
  @tracked joints = [0, 0, 0, 0, 0, 0];
  @tracked loaded = false;
  @tracked errorMsg = null;

  canvas = null;
  engine = null;
  scene = null;
  jointMeshes = [];
  linkMeshes = [];

  get config() {
    return ROBOT_CONFIGS[this.selectedRobot];
  }

  get numJoints() {
    return this.config?.dh?.length ?? 0;
  }

  get endEffectorPos() {
    if (!this.config) return [0, 0, 0];
    const { endEffector } = forwardKinematics(this.config.dh, this.joints);
    return getPosition(endEffector).map(v => v.toFixed(3));
  }

  get dhTable() {
    if (!this.config) return [];
    return this.config.dh.map((link, i) => ({
      i: i + 1,
      theta: ((link.theta + (this.joints[i] ?? 0)) * 180 / Math.PI).toFixed(1),
      d: link.d.toFixed(4),
      a: link.a.toFixed(4),
      alpha: (link.alpha * 180 / Math.PI).toFixed(1),
    }));
  }

  @action
  async setup(el) {
    if (window.__armEngine) {
      window.__armEngine.dispose();
    }
    this.canvas = el.querySelector('#arm-canvas');
    await this.initBabylon();
    window.__armEngine = this.engine;
    this.loaded = true;
    this.updateArm();
  }

  willDestroy() {
    super.willDestroy();
    if (this.engine) {
      this.engine.dispose();
      window.__armEngine = null;
    }
  }

  async initBabylon() {
    try {
      const BABYLON = await import('@babylonjs/core');

      if (!BABYLON.Engine.isSupported()) {
        throw new Error('WebGL is not supported by your browser. If you are on Linux, you may need to enable hardware acceleration (e.g., chrome://settings/system) or force WebGL via chrome://flags/#ignore-gpu-blocklist. If you have been reloading the page often, you may have exhausted the WebGL context limit—please completely close this tab and open a new one.');
      }

      const engine = new BABYLON.Engine(this.canvas, true, {
        disableWebGL2Support: true,
        failIfMajorPerformanceCaveat: false
      });
      const scene = new BABYLON.Scene(engine);
      scene.clearColor = new BABYLON.Color4(0.06, 0.07, 0.09, 1);

      const camera = new BABYLON.ArcRotateCamera('cam', -Math.PI / 4, Math.PI / 3, 8,
        BABYLON.Vector3.Zero(), scene);
      camera.attachControl(this.canvas, true);
      camera.wheelPrecision = 30;

      new BABYLON.HemisphericLight('light', new BABYLON.Vector3(0, 1, 0.3), scene);

      this.engine = engine;
      this.scene = scene;
      this.BABYLON = BABYLON;

      this._rebuildSceneForRobot();

      engine.runRenderLoop(() => scene.render());

      // Resize handling
      const resizeObs = new ResizeObserver(() => engine.resize());
      resizeObs.observe(this.canvas);
    } catch (e) {
      this.errorMsg = String(e.stack || e);
      console.error('Arm visualizer init failed:', e);
    }
  }

  _armReach() {
    const dh = this.config?.dh;
    if (!dh) return 1;
    let reach = 0;
    for (const link of dh) reach += Math.abs(link.a) + Math.abs(link.d);
    return Math.max(reach, 0.1);
  }

  _rebuildSceneForRobot() {
    const B = this.BABYLON;
    const scene = this.scene;
    if (!B || !scene) return;

    for (const name of ['ground', 'base']) {
      const m = scene.getMeshByName(name);
      if (m) m.dispose();
    }
    for (const mat of ['gMat', 'baseMat']) {
      const m = scene.getMaterialByName(mat);
      if (m) m.dispose();
    }

    const reach = this._armReach();
    const gridSize = reach * 3;
    const ground = B.MeshBuilder.CreateGround('ground', { width: gridSize, height: gridSize, subdivisions: 10 }, scene);
    const gMat = new B.StandardMaterial('gMat', scene);
    gMat.diffuseColor = new B.Color3(0.3, 0.3, 0.35); // Lighter ground to contrast the black background
    gMat.wireframe = true;
    ground.material = gMat;

    new B.AxesViewer(scene, reach);

    const baseH = reach * 0.03;
    const baseDiam = reach * 0.06;
    const base = B.MeshBuilder.CreateCylinder('base', { height: baseH, diameter: baseDiam }, scene);
    const baseMat = new B.StandardMaterial('baseMat', scene);
    baseMat.diffuseColor = new B.Color3(0.3, 0.3, 0.35);
    base.material = baseMat;
    base.position.y = baseH / 2;

    this.createArmMeshes();
    this._frameCameraOnArm();
  }

  _frameCameraOnArm() {
    const B = this.BABYLON;
    if (!B || !this.scene || !this.config) return;

    const dh = this.config.dh;
    const n = dh.length;
    let minB = [Infinity, Infinity, Infinity];
    let maxB = [-Infinity, -Infinity, -Infinity];

    const sampleAngles = [-Math.PI, -Math.PI / 2, 0, Math.PI / 2, Math.PI];
    const recurse = (joints) => {
      if (joints.length === n) {
        const pos = getPosition(forwardKinematics(dh, joints).endEffector);
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

    const camera = this.scene.activeCamera;
    camera.setTarget(center);
    camera.radius = extent * 2.5; // Backed out a bit more to ensure visibility
    camera.minZ = 0.001; // Lowered minZ even further
    camera.maxZ = 1000;  // Explicitly set a far maxZ just in case
  }

  createArmMeshes() {
    const B = this.BABYLON;
    const scene = this.scene;
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

    const jointDiam = reach * 0.08;
    const linkDiam = reach * 0.04;

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

  updateArm() {
    if (!this.scene || !this.config) return;
    const B = this.BABYLON;
    const dh = this.config.dh;
    const { transforms } = forwardKinematics(dh, this.joints);

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
        // Force the scaling to be at least tiny, otherwise the mesh completely vanishes!
        this.linkMeshes[i].scaling = new B.Vector3(1, Math.max(len, 0.001), 1);

        if (len > 0.0001) {
          const up = new B.Vector3(0, 1, 0);
          const dirN = dir.normalize();
          const axis = B.Vector3.Cross(up, dirN);
          if (axis.length() > 0.0001) {
            const dot = Math.max(-1, Math.min(1, B.Vector3.Dot(up, dirN)));
            this.linkMeshes[i].rotationQuaternion = B.Quaternion.RotationAxis(axis.normalize(), Math.acos(dot));
          } else {
            if (B.Vector3.Dot(up, dirN) < 0) {
              this.linkMeshes[i].rotationQuaternion = B.Quaternion.RotationAxis(new B.Vector3(1, 0, 0), Math.PI);
            } else {
              this.linkMeshes[i].rotationQuaternion = B.Quaternion.Identity();
            }
          }
          this.linkMeshes[i].isVisible = true;
        } else {
          this.linkMeshes[i].rotationQuaternion = B.Quaternion.Identity();
          // If the link has literally zero length (like the dummy links in Puma), hide it entirely
          this.linkMeshes[i].isVisible = false;
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

  @action
  selectRobot(e) {
    this.selectedRobot = e.target.value;
    this.joints = new Array(this.numJoints).fill(0);
    this._rebuildSceneForRobot();
    this.updateArm();
  }

  @action
  onJoint(idx, e) {
    const val = parseFloat(e.target.value);
    const newJoints = [...this.joints];
    newJoints[idx] = (val * Math.PI) / 180;
    this.joints = newJoints;
    this.updateArm();
  }

  @action
  loadPose(poseName) {
    const poses = this.config?.poses;
    if (poses && poses[poseName]) {
      this.joints = [...poses[poseName]];
      this.updateArm();
    }
  }

  <template>
    <div class="page-header">
      <h2>🦾 Robot Arm Visualizer</h2>
      <p>Interactive 3D visualization of a robot arm computed via forward kinematics from DH (Denavit-Hartenberg) parameters. Drag to orbit, scroll to zoom.</p>
    </div>

    <div {{didInsert this.setup}} class="grid-2">
      <div class="card span-2">
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">
          The 3D view shows the arm's current configuration. Each joint is a sphere, each link is a cylinder.
          Use the sliders on the right to change joint angles and see how the end-effector moves in real time.
          Preset buttons load common arm poses.
        </p>
        <div class="controls">
          <label>Robot:</label>
          <select {{on "change" this.selectRobot}}>
            <option value="puma560" selected>Puma 560 (6-DOF)</option>
            <option value="threeLink">3-Link 3D</option>
          </select>
          {{#if this.config.poses}}
            {{#each-in this.config.poses as |name angles|}}
              <button type="button" {{on "click" (fn this.loadPose name)}}>{{name}}</button>
            {{/each-in}}
          {{/if}}
        </div>
        <div class="canvas-wrap" style="height:450px;position:relative">
          {{#if this.errorMsg}}
            <div style="position:absolute;z-index:10;background:rgba(255,0,0,0.8);color:white;padding:1rem;inset:0;overflow:auto">
              <strong>Error rendering 3D view:</strong>
              <pre style="white-space:pre-wrap;font-size:11px">{{this.errorMsg}}</pre>
            </div>
          {{/if}}
          <canvas id="arm-canvas" style="width:100%;height:100%"></canvas>
        </div>
      </div>

      <div class="card">
        <h3 class="card-title">Joint Angles</h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">Drag sliders to rotate each joint. Values are in degrees (-180° to 180°).</p>
        {{#each this.dhTable as |link|}}
          <div class="slider-group">
            <label>q{{link.i}}</label>
            <input type="range" min="-180" max="180" value={{this.jointDeg link.i}}
              {{on "input" (fn this.onJoint (this.jointIdx link.i))}}>
            <span class="val">{{link.theta}}°</span>
          </div>
        {{/each}}
      </div>

      <div class="card">
        <h3 class="card-title">DH Parameters</h3>
        <p style="font-size:0.75rem;color:var(--text-dim);margin:0 0 0.5rem">The Denavit-Hartenberg table defines each link's geometry. θ is the joint angle, d is the link offset along Z, a is the link length along X, and α is the twist angle between consecutive Z axes.</p>
        <table class="info-table">
          <thead><tr><th>i</th><th>θ (°)</th><th>d</th><th>a</th><th>α (°)</th></tr></thead>
          <tbody>
            {{#each this.dhTable as |link|}}
              <tr>
                <td>{{link.i}}</td><td>{{link.theta}}</td>
                <td>{{link.d}}</td><td>{{link.a}}</td><td>{{link.alpha}}</td>
              </tr>
            {{/each}}
          </tbody>
        </table>
        <div style="margin-top:0.75rem">
          <h4 style="font-size:0.85rem;color:var(--accent)">End Effector</h4>
          <p style="font-size:0.8rem">
            [{{this.endEffectorPos}}]
          </p>
        </div>
      </div>
    </div>
  </template>

  jointDeg = (i) => {
    const rad = this.joints[i - 1] ?? 0;
    return Math.round(rad * 180 / Math.PI);
  }

  jointIdx = (i) => i - 1;
}

<template><ArmPage /></template>
