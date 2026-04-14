# ROB

Robotics course project at FIB-UPC, using the Robotics, Vision & Control (RVC) Toolbox for MATLAB.

## Overview

Covers robotics and computer vision topics including:

- Image processing (SURF, SIFT feature detection)
- Camera models and pose estimation (EKF)
- Visual servoing (IBVS/PBVS)
- Simulink models (e.g. quadcopter visual servoing)

## Structure

```
├── rvctools/
│   ├── vision/             # Computer vision functions (.m)
│   │   ├── mex/            # C/C++ MEX extensions (SURF, apriltags)
│   │   └── simulink/       # Simulink models (.mdl)
│   ├── spatial-math/       # Spatial math utilities (.m)
│   └── startup_rvc.m       # Toolbox initialization
└── slprj/                  # Simulink project files (EKF pose estimation)
```

## Tech Stack

- **MATLAB** with Image Processing, Computer Vision, and Statistics toolboxes
- **Simulink** for control system modeling
- **C/C++ MEX** for performance-critical operations

## Web Dashboard

Interactive robotics visualizations built with **Ember.js 6** + **Babylon.js**. Runs on port **8092**.

### Features

| Page | Description |
|------|-------------|
| **Overview** | Landing page with feature cards and data source table |
| **Mobile Robot** | Replay real encoder & laser data with differential-drive odometry |
| **Wall Following** | Reactive controller simulation (k1/k2/k3 gains, raycasting) |
| **Robot Arm** | 3D forward kinematics (Puma560, 3-Link) with joint sliders |
| **Trajectory** | Joint-space interpolation between waypoints + EE path |
| **Sensors** | Encoder angular speed, laser distance, polar scan viewer |
| **EKF** | Extended Kalman Filter with covariance ellipses |

### Quick Start

```bash
# Development
cd web && npm install && npx ember serve --port 8092

# Docker
make docker-up      # Build & run at http://localhost:8092
make docker-rebuild  # Full no-cache rebuild

# Convert MATLAB .mat data to JSON
make data
```

### Data Pipeline

`scripts/mat2json.py` converts MATLAB `.mat` sensor data to JSON:
- `encoder.json` – 3,004 left/right wheel encoder samples
- `laser.json` – 3,000 laser sonar bearings & distances
- `sensors.json` – Angular speeds + 149 polar laser scans (683 → 227 beams)
- `waypoints.json` – 35 reference waypoints
- `map1.json` – 100×100 occupancy grid
