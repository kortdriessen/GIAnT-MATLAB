function processTrialBatch(inputFile, batchFile, outputFile)
%PROCESSTRIALBATCH Extract one batch of trials; entry point of a separate MATLAB process.
%   processTrialBatch(inputFile, batchFile, outputFile) is run by
%   processAllTrials_Isolated as
%       matlab -batch "processTrialBatch('inputs.mat', 'batch_001.mat', 'result_001.mat')"
%   It restores the calling process's MATLAB path, runs processAllTrials_Async
%   on the trials listed in batchFile with the shared inputs in inputFile, and
%   saves the per-trial results E to outputFile. All of the process's memory
%   is returned to the operating system when it exits.
%
%   See also processAllTrials_Isolated, processAllTrials_Async.

fprintf('=== trial batch process start (PID %d) ===\n', feature('getpid'));

tmp = load(inputFile, 'matlabPath');
path(tmp.matlabPath);
clear tmp

in = load(inputFile, 'dr', 'fns', 'fls', 'els', 'selPix', 'sources', 'discardFrames', ...
    'alignData', 'meanAligned', 'motOutput', 'roiData', 'params');
batch = load(batchFile, 'batchTrials');

E = processAllTrials_Async(in.dr, in.fns, in.fls, in.els, in.selPix, in.sources, ...
    in.discardFrames, in.alignData, in.meanAligned, in.motOutput, in.roiData, ...
    batch.batchTrials, in.params);

%write to a temporary name and rename, so a crash mid-save leaves no result file
partialFile = [outputFile '.partial.mat'];
save(partialFile, 'E', '-v7.3');
movefile(partialFile, outputFile);

delete(gcp('nocreate'));
fprintf('=== trial batch process done ===\n');
end
