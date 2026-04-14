#!/usr/bin/env python3
"""Convert .mat data files to JSON for the ROB web dashboard."""

import json
import os
import sys
import numpy as np
import scipy.io

OUT = os.path.join(os.path.dirname(__file__), '..', 'web', 'public', 'data')
os.makedirs(OUT, exist_ok=True)

def to_list(arr):
    """Convert numpy array to nested Python lists, handling NaN/Inf."""
    if isinstance(arr, np.ndarray):
        arr = np.where(np.isfinite(arr), arr, 0).tolist()
    return arr

def convert_encoder(path, name):
    d = scipy.io.loadmat(path)
    out = {
        'L_acu': to_list(d['L_acu']),
        'R_acu': to_list(d['R_acu']),
        'Tf': float(d['Tf'].flat[0]),
        'Ts': float(d['Ts'].flat[0]),
        'W': float(d['W'].flat[0]),
        'r_w': float(d['r_w'].flat[0]),
    }
    with open(os.path.join(OUT, name), 'w') as f:
        json.dump(out, f)
    print(f'  -> {name} ({len(out["L_acu"])} samples)')

def convert_laser(path, name):
    d = scipy.io.loadmat(path)
    out = {
        'l_s_b': to_list(d['l_s_b']),
        'l_s_d': to_list(d['l_s_d']),
    }
    with open(os.path.join(OUT, name), 'w') as f:
        json.dump(out, f)
    print(f'  -> {name} (bearing:{len(out["l_s_b"])} dist:{len(out["l_s_d"])})')

def convert_sensors(path, name):
    d = scipy.io.loadmat(path)
    # Downsample laser scans (149x683 is large)
    log_urg = d['log_urg']
    polar = d['polar_laser_data']
    # Keep every scan but limit to 180 beams (skip every 4th)
    step = max(1, log_urg.shape[1] // 180)
    out = {
        'left_angular_speed': to_list(d['left_angular_speed']),
        'right_angular_speed': to_list(d['right_angular_speed']),
        'log_urg': to_list(log_urg[:, ::step]),
        'polar_laser_data': to_list(polar[:, ::step]),
        'laser_step': step,
        'original_beams': int(log_urg.shape[1]),
    }
    with open(os.path.join(OUT, name), 'w') as f:
        json.dump(out, f)
    print(f'  -> {name} (scans:{log_urg.shape[0]} beams:{log_urg.shape[1]}->{log_urg.shape[1]//step})')

def convert_waypoints(path, name):
    d = scipy.io.loadmat(path)
    wp = d['wp']
    out = {
        'waypoints': to_list(wp),
    }
    with open(os.path.join(OUT, name), 'w') as f:
        json.dump(out, f)
    print(f'  -> {name} ({wp.shape[1]} waypoints)')

def convert_map(path, name):
    d = scipy.io.loadmat(path)
    out = {
        'map': to_list(d['map']),
        'rows': int(d['map'].shape[0]),
        'cols': int(d['map'].shape[1]),
    }
    with open(os.path.join(OUT, name), 'w') as f:
        json.dump(out, f)
    print(f'  -> {name} ({out["rows"]}x{out["cols"]})')


BASE = '/home/pol/cuberhaus/ROB/ROB'

conversions = [
    (convert_encoder, f'{BASE}/Mobile Robot_Short project/Encoder_Data.mat', 'encoder.json'),
    (convert_laser, f'{BASE}/Mobile Robot_Short project/Laser_Data.mat', 'laser.json'),
    (convert_sensors, f'{BASE}/Mobile Robot_Short project/Sensors_Data.mat', 'sensors.json'),
    (convert_waypoints, f'{BASE}/Mobile Robot_Short project/way_points_2.mat', 'waypoints.json'),
    (convert_encoder, f'{BASE}/lab6/Encoder_Data.mat', 'encoder_lab6.json'),
    (convert_map, f'{BASE}/rvctools/robot/data/map1.mat', 'map1.json'),
]

print('Converting .mat -> JSON ...')
for fn, path, name in conversions:
    try:
        fn(path, name)
    except Exception as e:
        print(f'  SKIP {name}: {e}', file=sys.stderr)
print('Done.')
