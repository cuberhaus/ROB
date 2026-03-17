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
