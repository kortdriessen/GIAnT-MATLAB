function run_slap2_wisc(acqDir, savedr)
%RUN_SLAP2_WISC Run the full GIAnT SLAP2 pipeline on one Wisconsin acquisition.
%   run_slap2_wisc(acqDir) builds the trial table, runs MultiRoiRegistration,
%   and runs SILo on the acquisition folder acqDir (the folder holding the
%   .dat files). Outputs are written beneath acqDir.
%
%   run_slap2_wisc(acqDir, savedr) writes outputs beneath savedr instead.
%
%   Wisconsin-specific settings live here so that the rest of the repository
%   can track AllenNeuralDynamics/GIAnT-MATLAB without local edits:
%     - activityChannel = 2: on our rigs raw channel 1 is jRGECO1a (calcium)
%       and raw channel 2 is iGluSnFR4f (glutamate). GIAnT's default is 1.
%     - All files in the folder form a single epoch (no file-picker dialog).
%   Parameters passed explicitly bypass the parameter GUIs; the user-ROI
%   drawing GUI still opens unless annotations.h5 already exists.

arguments
    acqDir (1,:) char {mustBeFolder}
    savedr (1,:) char = acqDir
end

disp(['run_slap2_wisc started at: ' char(datetime("now"))])

buildTrialTableSLAP2(acqDir, savedr, true);
trialTablePath = fullfile(savedr, 'trial_table.h5');

alignParams = struct();
MultiRoiRegistration(trialTablePath, alignParams);

siloParams = struct();
siloParams.isSLAP2 = true;
siloParams.activityChannel = 2;
SILo(trialTablePath, siloParams);

disp(['run_slap2_wisc finished at: ' char(datetime("now"))])
end
