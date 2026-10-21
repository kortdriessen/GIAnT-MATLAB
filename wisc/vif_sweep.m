function vif_sweep(savedr, vifValues, opts)
%VIF_SWEEP Activity images and detected sources across a range of VIF values.
%   VIF_SWEEP(savedr, vifValues) re-runs SILo's localization only (per-trial
%   activity images -> combined act_im -> source selection, no trace
%   extraction) for each VIF value, reusing the motion correction and
%   annotations already in savedr (the GIAnT save folder holding
%   trial_table.h5, motion_correction/ and annotations/annotations.h5).
%
%   For each value it writes  <savedr>/vif_sweep/VIF_<value>/
%       localization.h5  act_im, soma_mask, px_always_valid, mean_im,
%                        valid_trials and sources at params.peakth, per Path
%       detections.h5    sources for every threshold in opts.peakthGrid
%                        (see detect_threshold_grid), for interactive viewing
%
%   VIF_SWEEP(..., Name=Value):
%       peakthGrid  thresholds for detections.h5 (default 2:0.25:20)
%       outName     subfolder name (default 'vif_sweep')
%       overwrite   recompute existing outputs (default false)
%       nWorkers    SILo parallel workers (default: SILo's default)
%       detectWorkers  workers for the threshold grid (default 8; 0 = serial)
%
%       tau_s       glutamate kernel / activity-filter time constant
%                   (default 0.030, the Wisconsin setting; see run_slap2_wisc)
%
%   Wisconsin settings (activityChannel = 2, isSLAP2, tau_s) match run_slap2_wisc.
%   Example:
%       vif_sweep('/data/temp/slap_processing_testing/giant_defaults', [1.67 3 5 8 10 15 20])

arguments
    savedr (1,:) char {mustBeFolder}
    vifValues (1,:) double {mustBePositive}
    opts.peakthGrid (1,:) double = 2:0.25:20
    opts.outName (1,:) char = 'vif_sweep'
    opts.overwrite (1,1) logical = false
    opts.nWorkers double = []
    opts.detectWorkers (1,1) double {mustBeNonnegative, mustBeInteger} = 8
    opts.tau_s (1,1) double {mustBePositive} = 0.030
end

trialTablePath = fullfile(savedr, 'trial_table.h5');
assert(isfile(trialTablePath), 'vif_sweep:noTrialTable', 'No trial_table.h5 in %s', savedr);
assert(isfile(fullfile(savedr, 'annotations', 'annotations.h5')), 'vif_sweep:noAnnotations', ...
    ['No annotations/annotations.h5 in %s. Run SILo (or annotateROIs) once first, ' ...
     'otherwise the ROI-drawing GUI would open for every VIF value.'], savedr);

for vif = vifValues
    outDir = fullfile(savedr, opts.outName, sprintf('VIF_%g', vif));
    if ~exist(outDir, 'dir')
        mkdir(outDir);
    end
    locFile = fullfile(outDir, 'localization.h5');
    detFile = fullfile(outDir, 'detections.h5');

    if opts.overwrite || ~isfile(locFile)
        fprintf('\n=== VIF %g: localization -> %s\n', vif, locFile);
        p = struct();
        p.isSLAP2 = true;
        p.activityChannel = 2;
        p.VIF = vif;
        p.tau_s = opts.tau_s;
        p.localizeOnly = true;
        p.localizeOutputFile = locFile;
        if ~isempty(opts.nWorkers)
            p.nWorkers = opts.nWorkers;
        end
        SILo(trialTablePath, p);
    end

    if opts.overwrite || ~isfile(detFile)
        fprintf('\n=== VIF %g: detections over %d thresholds -> %s\n', vif, numel(opts.peakthGrid), detFile);
        detect_threshold_grid(locFile, detFile, opts.peakthGrid, opts.detectWorkers);
    end
end
delete(gcp('nocreate'));
end
