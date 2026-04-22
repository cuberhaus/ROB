# Collision Detection in Real Games

When writing a simple physics simulation or a 2D canvas game with a few dozen walls, a basic looping function checking every single object is perfectly fine. However, as the world scales up, this approach quickly becomes a performance bottleneck. 

Real game engines split collision detection into two distinct phases to handle massive worlds efficiently: **Broad Phase** and **Narrow Phase**.

---

## 1. The Broad Phase (Fast Rejection)

The first step is to quickly eliminate any objects that are obviously too far away to collide. 

### AABB (Axis-Aligned Bounding Box)
The most fundamental Broad Phase check is the AABB. Instead of calculating complex shapes or exact line segments, the engine draws a simple invisible "box" around both objects. 

It checks if the boxes overlap using simple less-than (`<`) and greater-than (`>`) operators:
- Is the right edge of Box A to the left of the left edge of Box B?
- Is the bottom edge of Box A above the top edge of Box B?

If the boxes don't overlap, the objects physically cannot be touching, so the engine completely skips the heavy math and moves on.

*Note: This is exactly what we implemented in the wall-following simulator to optimize the wall checks!*

---

## 2. The Narrow Phase (Exact Math)

If the Broad Phase determines that two AABBs *are* overlapping, the engine moves to the Narrow Phase. This is where the expensive math happens. 

The engine will calculate the exact distance and intersection between the specific geometric shapes of the objects:
- Point-to-segment distance (like our `distToSegmentSquared` function)
- Circle-to-circle intersection
- Polygon intersection (using algorithms like SAT - Separating Axis Theorem or GJK)

Because the Broad Phase filtered out 99% of the objects, the engine only has to perform this heavy math on the 1 or 2 objects the player is actually touching.

---

## 3. Spatial Partitioning (Scaling to Millions of Objects)

Even with AABB fast-rejection, checking a player's bounding box against 1,000,000 objects every frame (60 times a second) will freeze the CPU. 

To solve this, real game engines (like Unity, Unreal, or Godot) divide the game world into searchable structures so they only check objects that are in the same "chunk" as the player. This is called **Spatial Partitioning**.

### A. Spatial Grids (Like Minecraft)
The entire world is divided into a 2D or 3D grid of "cells" or "chunks". When the player moves, the game tracks which cell they are in (e.g., `Cell [5, 12]`). The engine then only performs the AABB Broad Phase against the walls that are registered inside `Cell [5, 12]` and its immediate neighbors. It completely ignores the rest of the world.

### B. Quadtrees (2D) / Octrees (3D)
Instead of a uniform grid, the world is divided dynamically. A massive empty field is just one giant square box. But a crowded town is subdivided into 4 smaller boxes. If those boxes are still crowded, they divide into 4 even smaller boxes, and so on. 

When checking for collisions, the engine quickly walks down this "tree" of boxes to find exactly which tiny localized box the player is standing in, and only checks collisions against the objects inside it.

### C. Bounding Volume Hierarchies (BVH)
Instead of dividing the *space* of the world, this groups the *objects*. If a house has 100 walls, the engine wraps a giant invisible box around the entire house. 

If the player isn't touching the giant "House Box", the engine immediately knows it doesn't need to check any of the 100 individual walls inside the house. If they *are* touching the House Box, the engine "opens" the box and checks the walls inside.

---

## Summary
For a simple 2D canvas simulator with fewer than a few hundred walls, a loop with an AABB fast-rejection is exactly how a professional would write it. The overhead of building a complex Quadtree wouldn't be worth it. 

But if you ever decide to turn your simulator into a massive 10,000-wall maze, you would want to implement a **Spatial Grid** or a **Quadtree** to maintain 60 FPS!