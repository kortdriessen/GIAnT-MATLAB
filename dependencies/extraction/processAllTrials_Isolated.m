function E = processAllTrials_Isolated(dr, fns, fls, els, selPix, sources, discardFrames, alignData, meanAligned, motOutput, roiData, validTrials, params, workDr)
%PROCESSALLTRIALS_ISOLATED processAllTrials_Async run in separate MATLAB processes.
%   E = processAllTrials_Isolated(<processAllTrials_Async inputs>, workDr)
%   takes the same inputs and returns the same per-trial results E as
%   processAllTrials_Async. The valid trials are split into batches of
%   params.trialsPerProcess trials, and each batch runs processAllTrials_Async
%   in its own `matlab -batch` process (processTrialBatch). The batch results
%   are merged into E.
%
%   Why: on Linux the main MATLAB process does not give memory freed between
%   trials back to the operating system, so its resident memory grows with
%   every trial (about 4.8 GB per trial on a 214-source SLAP2 path, measured
%   2026-11-09) and long recordings run out of memory. A process's memory is
%   returned in full when it exits, so peak memory is bounded by one batch and
%   nothing is carried over to the next imaging path. Trials are extracted
%   independently, so the results are identical to processing them all in
%   this process.
%
%   workDr is a folder for the hand-off files (inputs once, one result file per
%   batch). Use a folder on disk, not tempdir: /tmp is RAM-backed on Linux
%   workstations, and the inputs and results can be several GB. The files are
%   deleted when this function returns.
%
%   See also processAllTrials_Async, processTrialBatch.

numDatasets = numel(fls);
E = cell(numDatasets, 1);
if isempty(validTrials)
    return
end

trialsPerProcess = params.trialsPerProcess;
nValid = numel(validTrials);
nBatches = ceil(nValid / trialsPerProcess);
batchEdges = round(linspace(0, nValid, nBatches + 1)); %near-equal batches

%the batch processes start their own worker pool; an idle pool in this
%process would only hold memory meanwhile (SILo restarts its pool as needed)
delete(gcp('nocreate'));

jobDr = tempname(workDr);
mkdir(jobDr);
cleanup = onCleanup(@() rmdir(jobDr, 's'));

%inputs shared by all batches, written once
inputFile = fullfile(jobDr, 'inputs.mat');
matlabPath = path(); %saved for processTrialBatch
fprintf('Trial extraction in %d separate MATLAB processes (%d valid trials, up to %d per process)\n', ...
    nBatches, nValid, trialsPerProcess);
save(inputFile, 'dr', 'fns', 'fls', 'els', 'selPix', 'sources', 'discardFrames', ...
    'alignData', 'meanAligned', 'motOutput', 'roiData', 'params', 'matlabPath', '-v7.3');

matlabBin = fullfile(matlabroot, 'bin', 'matlab');
codeDr = fileparts(mfilename('fullpath'));
for batchIx = 1:nBatches
    batchTrials = validTrials(batchEdges(batchIx)+1:batchEdges(batchIx+1)); %saved below
    batchFile = fullfile(jobDr, sprintf('batch_%03d.mat', batchIx));
    outputFile = fullfile(jobDr, sprintf('result_%03d.mat', batchIx));
    save(batchFile, 'batchTrials');

    fprintf('[trial batch %d/%d] trials %s in a new MATLAB process\n', ...
        batchIx, nBatches, compactRange(validTrials(batchEdges(batchIx)+1:batchEdges(batchIx+1))));
    cmd = sprintf('"%s" -batch "addpath(%s); processTrialBatch(%s, %s, %s)"', matlabBin, ...
        quoteForMatlab(codeDr), quoteForMatlab(inputFile), quoteForMatlab(batchFile), quoteForMatlab(outputFile));
    status = system(cmd); %output streams to this process's console
    if status ~= 0 || ~isfile(outputFile)
        error('processAllTrials_Isolated:batchFailed', ...
            'Trial batch %d/%d failed (exit status %d); see the output above.', batchIx, nBatches, status);
    end

    batchResult = load(outputFile, 'E');
    for trialIx = 1:numDatasets
        if ~isempty(batchResult.E{trialIx})
            E{trialIx} = batchResult.E{trialIx};
        end
    end
    delete(batchFile, outputFile);
end
end

function s = quoteForMatlab(str)
%a MATLAB char literal for str, for a -batch command line
s = ['''' strrep(str, '''', '''''') ''''];
end

function s = compactRange(trials)
%"3-7" for consecutive trial numbers, else a list
if numel(trials) > 1 && all(diff(trials) == 1)
    s = sprintf('%d-%d', trials(1), trials(end));
else
    s = mat2str(trials);
end
end
