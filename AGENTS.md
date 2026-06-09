# ROB

Frozen FIB-UPC robotics coursework: forward kinematics, odometry, EKF localization, and wall-following, built on Peter Corke's Robotics/Vision/Control (RVC) Toolbox for MATLAB. A small Ember.js + Babylon.js web dashboard (in [web/](web/)) replays the lab data in the browser.

## Architecture
- [ROB/](ROB/) — per-lab MATLAB scripts/functions (`lab0`–`lab7`, `Mobile Robot_Short project/`) plus Simulink models and the bundled `rvctools/` copy.
- [scripts/mat2json.py](scripts/mat2json.py) — converts MATLAB `.mat` sensor data to JSON for the web dashboard.
- [web/](web/) — Ember.js 6 + Babylon.js visualizer (encoder/laser replay, EKF, wall-following, FK).

## Build and Test
- MATLAB labs: open MATLAB, run `ROB/rvctools/startup_rvc.m` to add the RVC Toolbox to the path, then run lab scripts from their folder.
- Web dashboard: `make docker-up` (http://localhost:8092) or `cd web && npm install && npx ember serve --port 8092`.
- Regenerate JSON data: `make data`.

## Pitfalls
- Coursework is frozen — do not refactor lab code; new work belongs in `web/` or `scripts/`.
- RVC Toolbox is vendored under `ROB/rvctools/`; do not assume a system MATLAB install provides it.
- Simulink models and `.mat` files require MATLAB — they cannot be exercised from the web/Docker side.

See [README.md](README.md).
