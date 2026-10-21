function detect_threshold_grid(locFile, outFile, peakthGrid, nWorkers)
%DETECT_THRESHOLD_GRID Run SILo's source selection at many peak thresholds.
%   DETECT_THRESHOLD_GRID(locFile, outFile, peakthGrid) loads a localization
%   file written by SILo with params.localizeOnly (see vif_sweep) and, for
%   each Path and each threshold in peakthGrid, runs selectSources - the
%   exact detection SILo uses - with params.peakth set to that threshold.
%
%   outFile (HDF5, via saveStructToH5) holds per Path one row per detected
%   source over all thresholds:
%       peakth  threshold the row belongs to
%       R, C    rounded 1-indexed row / col of the source seed
%       V       fitted peak amplitude
%   plus peakth_grid and n_sources (count per threshold). Thresholds are
%   independent; with nWorkers > 0 (default 8) they run on a process pool of
%   that size (an existing pool of that size is reused), otherwise serially.

if nargin < 4 || isempty(nWorkers)
    nWorkers = 8;
end
if nWorkers > 0
    pool = gcp('nocreate');
    if isempty(pool) || pool.NumWorkers ~= nWorkers || ~isa(pool, 'parallel.ProcessPool')
        delete(pool);
        parpool('Processes', nWorkers);
    end
end

loc = loadStructFromH5(locFile);
params = loc.params;
paths = fieldnames(loc);
paths = paths(startsWith(paths, 'Path'));

out = struct();
for k = 1:numel(paths)
    P = loc.(paths{k});
    actIM = double(P.act_im);
    somaMask = logical(P.soma_mask);
    pxAlwaysValid = logical(P.px_always_valid);
    nTh = numel(peakthGrid);
    found = cell(1, nTh);
    t = tic;
    parfor (thIx = 1:nTh, nWorkers)
        pp = params;
        pp.peakth = peakthGrid(thIx);
        s = selectSources(actIM, somaMask, pxAlwaysValid, pp);
        n = numel(s.R);
        found{thIx} = [repmat(peakthGrid(thIx), n, 1), s.R(:), s.C(:), s.V(:)];
    end
    rows = vertcat(found{:});
    if isempty(rows)
        rows = zeros(0, 4);
    end
    g = struct();
    g.peakth_grid = peakthGrid(:);
    g.n_sources = cellfun(@(x) size(x, 1), found)';
    g.peakth = rows(:,1);
    g.R = rows(:,2);
    g.C = rows(:,3);
    g.V = rows(:,4);
    out.(paths{k}) = g;
    fprintf('%s: %d thresholds in %.1f s; sources at %g..%g: %d..%d\n', paths{k}, nTh, toc(t), ...
        peakthGrid(1), peakthGrid(end), g.n_sources(1), g.n_sources(end));
end
out.params = params;
saveStructToH5(out, outFile);
end
