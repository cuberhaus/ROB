import { pageTitle } from 'ember-page-title';
import { LinkTo } from '@ember/routing';

const NAV_ITEMS = [
  { route: 'index', label: 'Overview' },
  { route: 'mobile', label: 'Mobile Robot' },
  { route: 'wall-following', label: 'Wall Following' },
  { route: 'arm', label: 'Robot Arm' },
  { route: 'trajectory', label: 'Trajectory' },
  { route: 'sensors', label: 'Sensors' },
  { route: 'ekf', label: 'EKF' },
];

<template>
  {{pageTitle "ROB – Robotics Dashboard"}}

  <div class="app-layout">
    <nav class="sidebar">
      <h1 class="sidebar-title">🤖 ROB</h1>
      <ul class="nav-list">
        {{#each NAV_ITEMS as |item|}}
          <li>
            <LinkTo @route={{item.route}} class="nav-link">
              {{item.label}}
            </LinkTo>
          </li>
        {{/each}}
      </ul>
    </nav>
    <main class="main-content">
      {{outlet}}
    </main>
  </div>
</template>
