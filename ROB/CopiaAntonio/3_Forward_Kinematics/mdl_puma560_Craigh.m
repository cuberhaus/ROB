%% mdl_puma560Craigh Create model of Puma 560 manipulator
%
% MDL_PUMA560AKB is a script that creates the workspace variable p560Craigh
% which describes the kinematic  of a Unimation
% Puma 560 manipulator modified DH conventions used in the book:
% Introduction to Robotics by John Craight.
%
% Also defines the workspace vectors:
%   qz         zero joint angle configuration
%   qr         vertical 'READY' configuration
%   qstretch   arm is stretched out in the X direction
%
% Notes::
% - SI units are used

%% Copyright (C) 1993-2015, by Peter I. Corke
%% modified by Antonio B. Martinez
%%
% http://www.petercorke.com

clear L
%            theta    d        a    alpha
L(1) = Link([  0      0        0       0       0], 'modified');
L(2) = Link([  0      0        0      -pi/2    0], 'modified');
L(3) = Link([  0      0.15005  0.4318  0       0], 'modified');
L(4) = Link([  0      0.4318   0.0203  -pi/2    0], 'modified');
L(5) = Link([  0      0        0       pi/2    0], 'modified');
L(6) = Link([  0      0        0       -pi/2    0], 'modified');



%
% some useful poses
%
qz = [0 0 0 0 0 0]; % zero angles, L shaped pose
qr = [0 -pi/2 -pi/2 0 0 0]; % ready pose, arm up
qstretch = [0 0 -pi/2 pi/2 0 0]; % horizontal along x-axis
qn=[0+pi/10 0-pi/10 -pi/2+pi/5 pi/2+pi/10 0 0]; % horizontal along x-axis

p560Craigh = SerialLink(L, 'name', 'Puma560-Craigh',...
                           'manufacturer', 'Unimation',...
                           'comment', 'Craigh');
clear L
