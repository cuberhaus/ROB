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
    const BABYLON = await import('@babylonjs/core');

    const engine = new BABYLON.Engine(this.canvas, true, { preserveDrawingBuffer: true });
    const scene = new BABYLON.Scene(engine);
    scene.clearColor = new BABYLON.Color4(0.06, 0.07, 0.09, 1);

    const camera = new BABYLON.ArcRotateCamera('cam', -Math.PI / 4, Math.PI / 3, 8,
      BABYLON.Vector3.Zero(), scene);
    camera.attachControl(this.canvas, true);
    camera.wheelPrecision = 30;

    new BABYLON.HemisphericLight('light', new BABYLON.Vector3(0, 1, 0.3), scene);

    // Ground grid
    const ground = BABYLON.MeshBuilder.CreateGround('ground', { width: 10, height: 10 }, scene);
    const gMat = new BABYLON.StandardMaterial('gMat', scene);
    gMat.diffuseColor = new BABYLON.Color3(0.1, 0.1, 0.12);
    gMat.wireframe = true;
    ground.material = gMat;

    // Base
    const base = BABYLON.MeshBuilder.CreateCylinder('base', { height: 0.3, diameter: 0.6 }, scene);
    const baseMat = new BABYLON.StandardMaterial('baseMat', scene);
    baseMat.diffuseColor = new BABYLON.Color3(0.3, 0.3, 0.35);
    base.material = baseMat;
    base.position.y = 0.15;

    this.engine = engine;
    this.scene = scene;
    this.BABYLON = BABYLON;

    // Create joint and link meshes
    this.createArmMeshes();

    engine.runRenderLoop(() => scene.render());

    // Resize handling
    const resizeObs = new ResizeObserver(() => engine.resize());
    resizeObs.observe(this.canvas);
  }

  createArmMeshes() {
    const B = this.BABYLON;
    const scene = this.scene;

    // Clean old meshes
    for (const m of this.jointMeshes) m.dispose();
    for (const m of this.linkMeshes) m.dispose();
    this.jointMeshes = [];
    this.linkMeshes = [];

    const n = this.numJoints;
    const jointMat = new B.StandardMaterial('jMat', scene);
    jointMat.diffuseColor = new B.Color3(0.3, 0.67, 0.93);
    const linkMat = new B.StandardMaterial('lMat', scene);
    linkMat.diffuseColor = new B.Color3(0.8, 0.8, 0.85);
    const eeMat = new B.StandardMaterial('eeMat', scene);
    eeMat.diffuseColor = new B.Color3(1, 0.42, 0.42);

    for (let i = 0; i < n; i++) {
      const joint = B.MeshBuilder.CreateSphere(`j${i}`, { diameter: 0.15 }, scene);
      joint.material = jointMat;
      this.jointMeshes.push(joint);

      const link = B.MeshBuilder.CreateCylinder(`l${i}`, { height: 1, diameter: 0.06 }, scene);
      link.material = linkMat;
      this.linkMeshes.push(link);
    }

    // End effector
    const ee = B.MeshBuilder.CreateSphere('ee', { diameter: 0.12 }, scene);
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

  @action
  selectRobot(e) {
    this.selectedRobot = e.target.value;
    this.joints = new Array(this.numJoints).fill(0);
    this.createArmMeshes();
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
        <div class="canvas-wrap" style="height:450px">
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
