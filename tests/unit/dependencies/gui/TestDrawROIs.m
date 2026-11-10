classdef TestDrawROIs < matlab.unittest.TestCase
    %TESTDRAWROIS Unit tests for the drawROIs annotation window.
    %   The window is created hidden; ROIs are added through loadROIsDirect
    %   and keys are sent through the figure's KeyPressFcn, so no mouse
    %   interaction is needed. Checks the exported roiData (masks, labels,
    %   types) that SILo and saveAnnotationsH5 rely on, the zoom/pan view
    %   limits, and ROI deletion.
    %   Run with: runtests('tests/unit/dependencies/gui/TestDrawROIs.m')

    properties (Constant)
        H = 120
        W = 200
    end

    properties
        tmpDir
        gui
        IM
    end

    methods (TestClassSetup)
        function addPaths(testCase)
            import matlab.unittest.fixtures.PathFixture
            testsDir = fileparts(mfilename('fullpath'));
            repoRoot = fileparts(fileparts(fileparts(fileparts(testsDir))));
            testCase.applyFixture(PathFixture(fullfile(repoRoot, 'dependencies', 'gui')));
            testCase.applyFixture(PathFixture(fullfile(repoRoot, 'dependencies', 'io')));
        end
    end

    methods (TestMethodSetup)
        function openWindow(testCase)
            import matlab.unittest.fixtures.TemporaryFolderFixture
            testCase.tmpDir = testCase.applyFixture(TemporaryFolderFixture).Folder;
            IM = zeros(testCase.H, testCase.W);
            IM(20:100, 30:170) = rand(81, 141); %sparse image, like SLAP2
            testCase.IM = IM;
            testCase.gui = drawROIs(IM, testCase.tmpDir, 'test_image', {}, 'Visible', 'off');
            testCase.addTeardown(@() delete(findall(groot, 'Type', 'figure', 'Tag', 'drawROIs')));
        end
    end

    methods
        function fnROIs = writeRois(testCase, roiData)
            fnROIs = fullfile(testCase.tmpDir, 'in_ROIs.mat');
            save(fnROIs, 'roiData');
        end

        function roiData = twoRois(testCase)
            P = [40 30; 90 35; 85 80; 45 75];
            roiData = {struct('Type', 'images.roi.polygon', 'Position', P, 'Label', 'soma1'), ...
                struct('Type', 'images.roi.ellipse', 'Center', [140 60], 'SemiAxes', [20 10], ...
                'RotationAngle', 30, 'Label', 'dend1')};
        end

        function key(testCase, k)
            f = testCase.gui.hF;
            f.KeyPressFcn(f, struct('Key', k, 'Modifier', {{}}));
        end
    end

    methods (Test)
        function exportsMasksAndLabels(testCase)
            roiData = testCase.twoRois();
            testCase.gui.loadROIsDirect(testCase.writeRois(roiData));
            testCase.gui.close();

            testCase.verifyFalse(isgraphics(testCase.gui.hF));
            R = testCase.gui.roiData;
            testCase.verifyNumElements(R, 2);
            P = roiData{1}.Position;
            testCase.verifyEqual(R{1}.mask, poly2mask(P(:,1), P(:,2), testCase.H, testCase.W));
            testCase.verifyEqual(R{1}.Label, 'soma1');
            testCase.verifyEqual(R{1}.Type, 'images.roi.polygon');
            testCase.verifyEqual(size(R{2}.mask), [testCase.H testCase.W]);
            testCase.verifyEqual(nnz(R{2}.mask), pi*20*10, 'RelTol', 0.05);
            testCase.verifyEqual(R{2}.Type, 'images.roi.ellipse');
            testCase.verifyFalse(any(isfield(R{1}, {'Parent', 'Children', 'ContextMenu'})));
        end

        function exportRoundTripsThroughAnnotationsH5(testCase)
            testCase.gui.loadROIsDirect(testCase.writeRois(testCase.twoRois()));
            testCase.gui.close();
            R = testCase.gui.roiData;
            fnH5 = fullfile(testCase.tmpDir, 'annotations.h5');
            saveAnnotationsH5(fnH5, struct('dr', testCase.tmpDir, 'fn', 'test_image', 'roiData', {R}));
            L = loadAnnotationsH5(fnH5);
            testCase.verifyEqual(logical(L(1).roiData{1}.mask), R{1}.mask);
            testCase.verifyEqual(logical(L(1).roiData{2}.mask), R{2}.mask);
            testCase.verifyEqual(L(1).roiData{2}.Label, 'dend1');
        end

        function incompleteRoisAreSkipped(testCase)
            roiData = [testCase.twoRois(), ...
                {struct('Type', 'images.roi.polygon', 'Position', zeros(0,2), 'Label', 'broken')}];
            testCase.verifyWarning(@() testCase.gui.loadROIsDirect(testCase.writeRois(roiData)), ...
                'drawROIs:IncompleteRois');
            testCase.verifyNumElements(testCase.gui.hROIs, 2);
        end

        function deleteKeyRemovesSelectedRoi(testCase)
            testCase.gui.loadROIsDirect(testCase.writeRois(testCase.twoRois()));
            list = testCase.gui.hList;
            list.Value = 1;
            list.Callback(list, []);
            testCase.key('delete');
            testCase.verifyNumElements(testCase.gui.hROIs, 1);
            testCase.verifyEqual(testCase.gui.hROIs{1}.Label, 'dend1');
            testCase.verifyEqual(list.String, {' 1  dend1            ellipse'});
            testCase.verifyEmpty(list.Value);

            testCase.gui.close();
            testCase.verifyNumElements(testCase.gui.roiData, 1);
        end

        function zoomStaysWithinTheImage(testCase)
            ax = testCase.gui.hAx;
            full = [diff(ax.XLim) diff(ax.YLim)];
            testCase.verifyGreaterThanOrEqual(max(full ./ [testCase.W testCase.H]), 1 - 1e-9, ...
                'fit view shows the whole image');
            testCase.key('equal');
            testCase.key('equal');
            testCase.verifyLessThan(diff(ax.XLim), full(1));
            testCase.verifyGreaterThanOrEqual(ax.XLim(1), 0.5 - 1e-9);
            testCase.verifyLessThanOrEqual(ax.XLim(2), testCase.W + 0.5 + 1e-9);
            for k = 1:50
                testCase.key('rightarrow');
            end
            testCase.verifyEqual(ax.XLim(2), testCase.W + 0.5, 'AbsTol', 1e-9, 'pan stops at the image edge');
            for k = 1:10
                testCase.key('hyphen');
            end
            testCase.verifyEqual([diff(ax.XLim) diff(ax.YLim)], full, 'AbsTol', 1e-9, ...
                'zooming out stops at the fit view');
        end

        function viewFillsAxesAspect(testCase)
            %the visible region matches the axes shape, so the image uses the whole window
            ax = testCase.gui.hAx;
            pos = getpixelposition(ax);
            testCase.verifyEqual(diff(ax.XLim) / diff(ax.YLim), pos(3) / pos(4), 'RelTol', 1e-9);
            testCase.key('equal');
            testCase.verifyEqual(diff(ax.XLim) / diff(ax.YLim), pos(3) / pos(4), 'RelTol', 1e-9);
        end

        function brightnessKeysChangeDisplayOnly(testCase)
            g = testCase.gui;
            before = g.hIm.CData;
            testCase.verifyEqual(before, single(repmat(annotationDisplayImage(testCase.IM), 1, 1, 3)), ...
                'default display is annotationDisplayImage');
            testCase.key('period');
            testCase.verifyGreaterThanOrEqual(g.hIm.CData, before);
            testCase.verifyLessThanOrEqual(max(g.hIm.CData(:)), 1);
            testCase.key('comma');
            testCase.verifyEqual(g.hIm.CData, before, 'AbsTol', 1e-6);
        end
    end
end
