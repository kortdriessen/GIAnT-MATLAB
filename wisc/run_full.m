% Run the full GIAnT SLAP2 pipeline (trial table -> MultiRoiRegistration -> SILo)
% on one acquisition. Wisconsin settings (activityChannel = 2, single epoch)
% live in wisc/run_slap2_wisc.m.
%
% Pick a save folder outside /data/raw_mirror for test runs: GIAnT writes
% trial_table.h5, motion_correction/, annotations/ and source_extraction/
% into it.

% Clean path: GIAnT shares many function names with ophys-slap2-analysis
% (setParams, extractTrial, processAllTrials_Async, ...), so the old pipeline
% must not be on the path.
restoredefaultpath;
addpath(genpath('/home/driessen2/slap2_processing/GIAnT-MATLAB'));
addpath('/home/driessen2/slap2_processing/Fast_Tiff_Write');           % pinned @ ddd50c3 (GIAnT README)
addpath(genpath('/home/driessen2/slap2_processing/slap2'), '-end');    % MBF slap2 reader @ 966a163c

dir = '/data/temp/slap_processing_testing/giant_defaults';
acqDir = dir;
savedr = dir;

run_slap2_wisc(acqDir, savedr);
