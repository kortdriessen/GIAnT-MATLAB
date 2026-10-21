function [sources, selPix] = selectSources(actIM, somaMask, pxAlwaysValid, params)
%SELECTSOURCES Detect source seeds on an activity image and build their pixel masks.
%   [sources, selPix] = SELECTSOURCES(actIM, somaMask, pxAlwaysValid, params)
%   runs getActImPeaks on actIM (excluding somaMask) with params.peakth and
%   params.minPeakDistance, removes duplicate seeds, dilates each seed into a
%   disk of radius ceil(2*params.dXY) restricted to pxAlwaysValid, and drops
%   seeds whose centre is not always valid or whose mask has <= 5 pixels.
%
%   sources: struct with fields R, C (rounded 1-indexed row/col) and V (fitted
%   amplitude), one entry per kept source.
%   selPix:  rows x cols x nSources logical masks.
%
%   This is the source-selection step of SILo, factored out so the same code
%   can be re-run cheaply on a saved activity image (e.g. threshold sweeps).

sz = size(actIM);
thetaf = getActImPeaks(actIM, params.peakth, somaMask, params.minPeakDistance);

sources = struct('R', [], 'C', [], 'V', []);
totalPix = sum(~isnan(actIM(:)) & ~somaMask(:));
if totalPix == 0 || isempty(thetaf)
    k = 0;
else
    sources.R = round(thetaf(:,2));
    sources.C = round(thetaf(:,3));
    sources.V = thetaf(:,1);

    % prune source seeds that are the same
    [~, uniqueIx] = unique([sources.R(:) sources.C(:)], 'rows', 'stable');
    sources.R = sources.R(uniqueIx);
    sources.C = sources.C(uniqueIx);
    sources.V = sources.V(uniqueIx);
    k = length(sources.R);
end

%select regions near synapses, aligned across movies
selPix = false([sz(1:2) k]);
selRadius = ceil(2*params.dXY);
for sourceIx = k:-1:1
    rr = round(sources.R(sourceIx));
    cc = round(sources.C(sourceIx));
    selPix(rr,cc,sourceIx) = true;
    selPix(:,:,sourceIx) = imdilate(selPix(:,:,sourceIx), strel('disk',selRadius));
end
selPix = selPix & repmat(pxAlwaysValid, 1, 1, k); %exclude poorly measured pixels

%prune any sources that got clipped by pixel selection
centerValid = pxAlwaysValid(sub2ind(size(pxAlwaysValid), sources.R, sources.C));
keepSources = squeeze(sum(selPix, [1 2]))>5 & centerValid(:);
if k > 0
    sources.R = sources.R(keepSources);
    sources.C = sources.C(keepSources);
    sources.V = sources.V(keepSources);
end
selPix = selPix(:,:,keepSources);
end
