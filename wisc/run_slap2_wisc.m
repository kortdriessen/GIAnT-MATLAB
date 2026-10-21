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
%     - tau_s = 0.030: measured on 46 acquisitions / 14 mice (slap_mi_2_sleep/
%       wisc_iglusnfr_decay_measurement, 2026-10-21). Our events are not
%       single-exponential; 0.030 s keeps ~99.6 % (200 Hz extraction) and
%       ~97.6 % (80 Hz activity image) of the best exponential filter's SNR,
%       GIAnT's default 0.024 s ~98.8 % / ~94 %.
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
siloParams.tau_s = 0.030;
SILo(trialTablePath, siloParams);

disp(['run_slap2_wisc finished at: ' char(datetime("now"))])
end
