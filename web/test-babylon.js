const BABYLON = require('@babylonjs/core');
// Mock canvas
const canvas = { width: 100, height: 100, style: {}, getContext: () => null, addEventListener: () => {} };
const engine = new BABYLON.Engine(null, true); // NullEngine for node
const scene = new BABYLON.Scene(engine);
const camera = new BABYLON.ArcRotateCamera('cam', -Math.PI / 4, Math.PI / 3, 8, BABYLON.Vector3.Zero(), scene);
console.log(scene.activeCamera === camera);
