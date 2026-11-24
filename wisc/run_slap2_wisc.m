function run_slap2_wisc(acqDir, savedr, steps, opts)
%RUN_SLAP2_WISC Run the full GIAnT SLAP2 pipeline on one Wisconsin acquisition.
%   run_slap2_wisc(acqDir) builds the trial table, runs MultiRoiRegistration,
%   and runs SILo on the acquisition folder acqDir (the folder holding the
%   .dat files). Outputs are written beneath acqDir.
%
%   run_slap2_wisc(acqDir, savedr) writes outputs beneath savedr instead.
%
%   run_slap2_wisc(acqDir, savedr, steps) runs only part of the pipeline:
%     "all"      - trial table, MultiRoiRegistration and SILo (default)
%     "register" - trial table and MultiRoiRegistration only
%     "silo"     - SILo only, on the trial_table.h5 and motion_correction/
%                  that a previous "register" run wrote to savedr
%   run_slap2_wisc(..., TrialsPerProcess=n) sets how many trials SILo
%   extracts per separate MATLAB process (default 20; 0 = all trials in the
%   main process, GIAnT's behaviour).
%
%   Between "register" and "silo", annotateROIs(fullfile(savedr,
%   'trial_table.h5')) draws the soma/user ROIs on the registered data, so
%   SILo then runs without opening the ROI GUI.
%
%   Wisconsin-specific settings live here so that the rest of the repository
%   can track AllenNeuralDynamics/GIAnT-MATLAB without local edits:
%     - activityChannel = 2: on our rigs raw channel 1 is jRGECO1a (calcium)
%       and raw channel 2 is iGluSnFR4f (glutamate). GIAnT's default is 1.
%     - tau_s = 0.030: measured on 46 acquisitions / 14 mice (slap_mi_2_sleep/
%       wisc_iglusnfr_decay_measurement, 2026-10-21). Our events are not
%       single-exponential; 0.030 s keeps ~99.6 % (200 Hz extraction) and
%       ~97.6 % (80 Hz activity image) of the best exponential filter's SNR,
%       GIAnT's default 0.024 s ~98.8 % / ~94 %.
%     - VIF = 15: our working default (2026-11-09), the value the
%       ophys-slap2-analysis pipeline effectively used (hard-coded in its
%       localizeSources_vIM.m). GIAnT's default is 1.67.
%     - peakth = 8: GIAnT's default, pinned here so an upstream change does
%       not silently change our source detection.
%     - trialsPerProcess = 20: SILo extracts trials in separate MATLAB
%       processes of up to 20 trials (processAllTrials_Isolated). On Linux
%       the main process keeps memory freed between trials (+4.8 GB per trial
%       on antares exp_2 acq_1 DMD2, 2026-11-09), which would exhaust RAM on
%       hour-long acquisitions. Results are identical to in-process extraction.
%     - All files in the folder form a single epoch (no file-picker dialog).
%   Parameters passed explicitly bypass the parameter GUIs; the user-ROI
%   drawing GUI still opens unless annotations.h5 already exists.

arguments
    acqDir (1,:) char {mustBeFolder}
    savedr (1,:) char = acqDir
    steps (1,1) string {mustBeMember(steps, ["all" "register" "silo"])} = "all"
    opts.TrialsPerProcess (1,1) double {mustBeInteger, mustBeNonnegative} = 20
end

disp(['run_slap2_wisc (' char(steps) ') started at: ' char(datetime("now"))])

removeTestFoldersFromPath();

trialTablePath = fullfile(savedr, 'trial_table.h5');

if steps ~= "silo"
    buildTrialTableSLAP2(acqDir, savedr, true);

    alignParams = struct();
    MultiRoiRegistration(trialTablePath, alignParams);
end

if steps ~= "register"
    if ~isfile(trialTablePath) || ~isfolder(fullfile(savedr, 'motion_correction'))
        error('run_slap2_wisc:NotRegistered', ...
            'No trial_table.h5 + motion_correction/ in %s; run the "register" step first.', savedr);
    end
    siloParams = struct();
    siloParams.isSLAP2 = true;
    siloParams.activityChannel = 2;
    siloParams.tau_s = 0.030;
    siloParams.VIF = 15;
    siloParams.peakth = 8;
    siloParams.trialsPerProcess = opts.TrialsPerProcess;
    SILo(trialTablePath, siloParams);
end

disp(['run_slap2_wisc finished at: ' char(datetime("now"))])
end

function removeTestFoldersFromPath()
%REMOVETESTFOLDERSFROMPATH Take GIAnT's tests/ folders off the MATLAB path.
%   addpath(genpath(<GIAnT>)) also adds tests/unit/**/fakes, whose test
%   doubles (slap2.Slap2DataFile, ScanImageTiffWrapper, Fast_BigTiff_Write,
%   processAllTrials_Async, ...) can shadow the real functions. The fake
%   slap2.Slap2DataFile reads a .dat file as text: slow, and totalNumLines
%   comes back NaN.
repoRoot = fileparts(fileparts(mfilename('fullpath')));
testsRoot = fullfile(repoRoot, 'tests');
entries = strsplit(path, pathsep);
isTest = startsWith(entries, testsRoot);
if any(isTest)
    rmpath(entries{isTest});
end
readerPath = which('slap2.Slap2DataFile');
assert(~isempty(readerPath) && ~startsWith(readerPath, repoRoot), ...
    'run_slap2_wisc:WrongReader', ...
    'slap2.Slap2DataFile resolves to "%s"; put the MBF slap2 repository on the path.', readerPath);
end
