import { LinkTo } from '@ember/routing';

const FEATURES = [
  { route: 'mobile', icon: '🚗', title: 'Mobile Robot Simulator',
    desc: 'Replay real odometry & laser data, build occupancy grid in real time.' },
  { route: 'wall-following', icon: '🧱', title: 'Wall-Following Simulator',
    desc: '2D environment with reactive wall-following controller (k1/k2/k3 gains).' },
  { route: 'arm', icon: '🦾', title: 'Robot Arm Visualizer',
    desc: '3D forward kinematics for Puma560, 3-Link, with joint sliders & DH table.' },
  { route: 'trajectory', icon: '📐', title: 'Trajectory Planner',
    desc: 'Waypoint editor with joint-space interpolation and Cartesian path preview.' },
  { route: 'sensors', icon: '📊', title: 'Sensor Dashboard',
    desc: 'Time-series encoder/laser plots with pose uncertainty zones.' },
  { route: 'ekf', icon: '🎯', title: 'EKF Visualizer',
    desc: 'Step through Extended Kalman Filter updates with covariance ellipses.' },
];

<template>
  <div class="page-header">
    <h2>ROB – Robotics Dashboard</h2>
    <p>Interactive visualizations for mobile robotics, kinematics, and state estimation.</p>
  </div>

  <div class="overview-grid">
    {{#each FEATURES as |f|}}
      <LinkTo @route={{f.route}} class="feature-card">
        <h3>{{f.icon}} {{f.title}}</h3>
        <p>{{f.desc}}</p>
      </LinkTo>
    {{/each}}
  </div>

  <div class="card" style="margin-top:1.5rem">
    <h3 class="card-title">Data Sources</h3>
    <table class="info-table">
      <thead><tr><th>File</th><th>Description</th><th>Samples</th></tr></thead>
      <tbody>
        <tr><td>encoder.json</td><td>Left/right wheel encoder (Mobile Robot)</td><td>3,004</td></tr>
        <tr><td>laser.json</td><td>Laser sonar bearings & distances</td><td>3,000</td></tr>
        <tr><td>sensors.json</td><td>Angular speed + polar laser scans</td><td>149 scans × 683 beams</td></tr>
        <tr><td>waypoints.json</td><td>Reference waypoints</td><td>35 waypoints</td></tr>
        <tr><td>map1.json</td><td>100×100 occupancy grid</td><td>10,000 cells</td></tr>
      </tbody>
    </table>
  </div>
</template>
