classdef drawROIs < handle
    %DRAWROIS Window for drawing user ROIs (somata, regions to exclude) on an image.
    %   obj = drawROIs(IM, dr, fn) opens a window showing IM (H x W, or
    %   H x W x 2 shown as ch1 red, ch2 cyan) in which the user draws and
    %   labels polygon and ellipse ROIs. SILo treats ROIs whose label contains
    %   "soma" as somata. dr is the default folder of Save ROIs / Load ROIs and
    %   fn names the image (window title, saved file names).
    %   obj = drawROIs(IM, dr, fn, shapedata) also outlines the boundaries in
    %   shapedata (cell array of [row col] vertex lists) in red.
    %   obj = drawROIs(..., 'Visible', 'off') creates the window hidden (tests).
    %
    %   When the window is closed (Done or the window's close button),
    %   obj.roiData holds one struct per ROI: its images.roi properties plus
    %   .mask (H x W logical). Callers wait for this with waitfor(obj.hF).
    %
    %   Controls (also listed in the window):
    %     P / E             draw a polygon / an ellipse
    %     L, or double-click an ROI in the list   rename the selected ROI
    %     Delete            delete the selected ROI
    %     scroll wheel      zoom in/out at the cursor;  + / -  zoom at the centre
    %     middle-drag, Shift-drag or arrow keys   pan;   F  fit the whole image
    %     . / ,             brighter / dimmer;   H  hide/show the ROIs
    %
    %   The window is an ordinary figure with axes rather than a uifigure:
    %   uifigure/uiaxes re-render slowly when a large window is resized, so
    %   the image lagged behind the window, froze, and ROI drawing misbehaved.

    properties
        hF;          %figure handle; deleted when the user is done
        hAx;         %axes handle
        hIm;         %image object
        hPanel;      %control panel on the right
        hStatus;     %hint line below the image
        hList;       %ROI list
        hBrightness; %brightness slider (log2 gain)
        hGamma;      %gamma slider
        hShowROIs;   %show/hide ROIs checkbox

        hROIs = {};  %images.roi objects, in drawing order
        roiData;     %ROI information for export; set when the window closes

        IMscaled;    %display image before gain/gamma: H x W x 3, >= 0, 1 = 99.9th percentile
        numChannels;
        fn;
        dr = [];
        drsave;
        fnsave;
        fnStem;
    end

    properties (Access = private)
        ctl;              %struct of the panel's uicontrols, for layout
        selectedIx = 0;   %index into hROIs of the selected ROI, 0 = none
        isDrawing = false;
        roiCounter = 0;   %for unique ROI tags
        roiTags = {};     %Tag of each hROIs entry (readable while an ROI is being deleted)
        viewCenter;       %[x y] data coordinates at the centre of the axes
        viewScale;        %image pixels per screen pixel
        isFitView = true; %keep the whole image in view when the window is resized
        panStart;         %{figure point, view centre} at the start of a pan drag
    end

    properties (Constant, Access = private)
        PanelWidth = 250;
        Margin = 8;
        StatusHeight = 22;
        RoiColor = [1 0.85 0.1];
        SelectedColor = [0.25 1 0.45];
        MaxZoom = 40; %screen pixels per image pixel
        IdleHint = ['Scroll: zoom   |   Middle-drag / Shift-drag / arrows: pan   |   F: fit image   |   ' ...
            'P: polygon   E: ellipse   |   . and , : brightness'];
        PolygonHint = ['POLYGON: click to add points, double-click to finish   |   Esc: cancel   |   ' ...
            'scroll to zoom and arrows to pan while drawing'];
        EllipseHint = 'ELLIPSE: click and drag   |   Esc: cancel';
    end

    methods
        function obj = drawROIs(IM, dr, fn, shapedata, opts)
            arguments
                IM
                dr
                fn
                shapedata = {}
                opts.Visible (1,:) char {mustBeMember(opts.Visible, {'on', 'off'})} = 'on'
            end
            obj.numChannels = size(IM,3);
            obj.dr = dr;
            obj.fn = fn;
            [~, obj.fnStem] = fileparts(fn);

            [~, IMscaled] = annotationDisplayImage(IM);
            if size(IMscaled, 3) == 1
                IMscaled = repmat(IMscaled, 1, 1, 3);
            end
            obj.IMscaled = single(IMscaled);

            obj.buildWindow();

            %plot outlines
            for k = 1:numel(shapedata)
                boundary = shapedata{k};
                plot(obj.hAx, boundary(:,2), boundary(:,1), 'r', 'HitTest', 'off', 'PickableParts', 'none')
            end

            obj.refreshList();
            obj.layout();
            obj.hF.SizeChangedFcn = @(~,~) obj.layout();
            obj.hF.Visible = opts.Visible;
        end

        function close(obj, ~, ~)
            %collect the ROIs (with masks) and close the window
            roiData = {};
            for rix = 1:numel(obj.hROIs)
                h = obj.hROIs{rix};
                if ~isvalid(h) || ~hasGeometry(h)
                    continue
                end
                try
                    S = roiStruct(h);
                    S.mask = createMask(h);
                    roiData = [roiData {S}]; %#ok<AGROW>
                catch ME
                    warning('drawROIs:RoiSkipped', 'ROI %d could not be exported and was skipped: %s', rix, ME.message);
                end
            end
            obj.roiData = roiData;
            delete(obj.hF); %not close(), which would re-enter CloseRequestFcn
        end

        function saveROIs(obj, ~, ~)
            if isempty(obj.drsave)
                obj.drsave = obj.dr;
            end
            [fnsave, drsave] = uiputfile(fullfile(obj.drsave, [obj.fnStem '_ROIs.mat']));
            if isequal(fnsave, 0)
                return
            end
            obj.fnsave = fnsave;
            obj.drsave = drsave;
            roiData = {};
            for rix = 1:numel(obj.hROIs)
                if isvalid(obj.hROIs{rix}) && hasGeometry(obj.hROIs{rix})
                    roiData = [roiData {roiStruct(obj.hROIs{rix})}]; %#ok<AGROW>
                end
            end
            obj.roiData = roiData;
            save(fullfile(obj.drsave, obj.fnsave), 'roiData');

            %save figure of the whole image
            disp('saving figure')
            view = {obj.viewCenter, obj.viewScale, obj.isFitView};
            obj.fitView();
            try
                exportgraphics(obj.hAx, fullfile(obj.drsave, [obj.fnStem '_FIGURE.pdf']), 'ContentType', 'vector');
            catch ME
                warning('drawROIs:FigureNotSaved', 'ROIs saved, but the figure could not be exported: %s', ME.message);
            end
            [obj.viewCenter, obj.viewScale, obj.isFitView] = view{:};
            obj.applyView();
        end

        function loadROIsDirect(obj, fnROIs)
            %replace the current ROIs with those saved in the .mat file fnROIs
            S = load(fnROIs, 'roiData');
            obj.restoreROIs(S.roiData);
        end

        function loadROIs(obj, ~, ~)
            if isempty(obj.drsave)
                obj.drsave = obj.dr;
            end
            [fnLoad, drLoad] = uigetfile(fullfile(obj.drsave, '*_ROIs.mat'));
            if isequal(fnLoad, 0)
                return
            end
            obj.loadROIsDirect(fullfile(drLoad, fnLoad));
        end

        function drawPolygon(obj, ~, ~)
            obj.drawROI('polygon');
        end

        function drawCircle(obj, ~, ~)
            obj.drawROI('ellipse');
        end

        function setLabel(obj, hROI)
            if ~isvalid(hROI)
                return
            end
            current = char(hROI.Label);
            if isempty(current)
                current = obj.suggestLabel();
            end
            label = inputdlg({'ROI label (a label containing "soma" marks a soma):'}, ...
                'ROI label', [1 60], {current});
            if ~isempty(label) && isvalid(hROI)
                hROI.Label = strtrim(label{1});
            end
            obj.refreshList();
        end
    end

    methods (Access = private)
        function buildWindow(obj)
            nOpen = numel(findall(groot, 'Type', 'figure', 'Tag', 'drawROIs'));
            offset = 0.03 * mod(nOpen, 3); %stagger the windows of the imaging paths
            obj.hF = figure('Name', ['ROI TRACING - ' obj.fn], 'NumberTitle', 'off', 'Tag', 'drawROIs', ...
                'MenuBar', 'none', 'ToolBar', 'none', 'Color', [0.16 0.16 0.16], ...
                'Units', 'normalized', 'OuterPosition', [0.03+offset, 0.08-offset, 0.9, 0.88], ...
                'Visible', 'off', 'HandleVisibility', 'callback', ...
                'KeyPressFcn', @obj.keyPress, ...
                'WindowScrollWheelFcn', @obj.scrollZoom, ...
                'WindowButtonDownFcn', @obj.buttonDown, ...
                'WindowButtonUpFcn', @obj.buttonUp, ...
                'CloseRequestFcn', @obj.close); %closing the window keeps ROIs, same as Done
            obj.hF.Units = 'pixels';

            obj.hAx = axes(obj.hF, 'Units', 'pixels', 'YDir', 'reverse', 'DataAspectRatio', [1 1 1], ...
                'NextPlot', 'add', 'Visible', 'off', 'HitTest', 'on', 'PickableParts', 'all');
            try
                disableDefaultInteractivity(obj.hAx); %zoom and pan are done here
                obj.hAx.Toolbar.Visible = 'off';
            catch
            end
            [H, W, ~] = size(obj.IMscaled);
            obj.hIm = image(obj.hAx, 'CData', obj.renderImage(), 'XData', [1 W], 'YData', [1 H], ...
                'HitTest', 'off', 'PickableParts', 'none');

            obj.hStatus = uicontrol(obj.hF, 'Style', 'text', 'HorizontalAlignment', 'left', ...
                'BackgroundColor', obj.hF.Color, 'ForegroundColor', [0.85 0.85 0.85], 'FontSize', 10, ...
                'String', obj.IdleHint);

            bg = [0.94 0.94 0.94];
            obj.hPanel = uipanel(obj.hF, 'Units', 'pixels', 'BackgroundColor', bg, 'BorderType', 'none');
            c = @(varargin) uicontrol(obj.hPanel, 'FontSize', 10, 'BackgroundColor', bg, varargin{:});
            ctl.title   = c('Style', 'text', 'String', 'ROIs', 'FontWeight', 'bold', 'FontSize', 12, 'HorizontalAlignment', 'left');
            ctl.poly    = c('Style', 'pushbutton', 'String', 'Draw Polygon  (P)', 'Callback', @obj.drawPolygon);
            ctl.ell     = c('Style', 'pushbutton', 'String', 'Draw Ellipse  (E)', 'Callback', @obj.drawCircle);
            ctl.list    = c('Style', 'listbox', 'BackgroundColor', [1 1 1], 'FontName', 'FixedWidth', ...
                'Min', 0, 'Max', 2, 'Value', [], 'Callback', @obj.listClicked); %Max-Min > 1 allows no selection
            ctl.rename  = c('Style', 'pushbutton', 'String', 'Rename (L)', 'Callback', @(~,~) obj.renameSelected());
            ctl.delete  = c('Style', 'pushbutton', 'String', 'Delete (Del)', 'Callback', @(~,~) obj.deleteSelected());
            ctl.show    = c('Style', 'checkbox', 'String', 'Show ROIs  (H)', 'Value', 1, 'Callback', @(~,~) obj.updateRoiVisibility());
            ctl.bLabel  = c('Style', 'text', 'String', 'Brightness  ( . and , )', 'HorizontalAlignment', 'left');
            ctl.bSlider = c('Style', 'slider', 'Min', -3, 'Max', 3, 'Value', 0, 'SliderStep', [1/24 1/6]);
            ctl.gLabel  = c('Style', 'text', 'String', 'Gamma', 'HorizontalAlignment', 'left');
            ctl.gSlider = c('Style', 'slider', 'Min', 0.25, 'Max', 2, 'Value', 1, 'SliderStep', [0.05/1.75 0.25/1.75]);
            ctl.fit     = c('Style', 'pushbutton', 'String', 'Fit Image  (F)', 'Callback', @(~,~) obj.fitView());
            ctl.save    = c('Style', 'pushbutton', 'String', 'Save ROIs...', 'Callback', @obj.saveROIs);
            ctl.load    = c('Style', 'pushbutton', 'String', 'Load ROIs...', 'Callback', @obj.loadROIs);
            ctl.done    = c('Style', 'pushbutton', 'String', 'Done', 'FontWeight', 'bold', 'FontSize', 11, ...
                'BackgroundColor', [0.75 0.9 0.75], 'Callback', @obj.close);
            ctl.help    = c('Style', 'text', 'HorizontalAlignment', 'left', 'FontSize', 9, 'String', { ...
                'Scroll wheel: zoom at the cursor', ...
                'Middle-drag, Shift-drag, arrows: pan', ...
                '+ / - : zoom,  F: fit the whole image', ...
                'Click an ROI to select it; drag it or', ...
                'its points to edit. Double-click an', ...
                'edge to add a point; right-click a', ...
                'point to delete it.', ...
                'Labels containing "soma" mark somata.', ...
                'Done or closing the window keeps ROIs.'});
            obj.ctl = ctl;
            obj.hList = ctl.list;
            obj.hBrightness = ctl.bSlider;
            obj.hGamma = ctl.gSlider;
            obj.hShowROIs = ctl.show;
            for s = [ctl.bSlider ctl.gSlider]
                s.Callback = @(~,~) obj.updateImage();
                addlistener(s, 'ContinuousValueChange', @(~,~) obj.updateImage());
            end
            %keys typed while a control has focus still reach the window,
            %except arrows in the list and sliders, which move those
            controls = struct2cell(ctl);
            for k = 1:numel(controls)
                h = controls{k};
                if any(strcmp(h.Style, {'listbox', 'slider'}))
                    h.KeyPressFcn = @(src, evt) obj.keyPress(src, evt, true);
                else
                    h.KeyPressFcn = @obj.keyPress;
                end
            end
        end

        function layout(obj)
            if ~isvalid(obj) || ~isgraphics(obj.hF)
                return
            end
            figPos = getpixelposition(obj.hF);
            W = figPos(3); H = figPos(4);
            m = obj.Margin; pw = obj.PanelWidth; sh = obj.StatusHeight;
            axW = max(W - pw - 3*m, 50);
            axH = max(H - sh - 3*m, 50);
            obj.hAx.Position = [m, sh + 2*m, axW, axH];
            obj.hStatus.Position = [m, m, axW, sh];
            ph = max(H - 2*m, 560);
            obj.hPanel.Position = [W - pw - m, H - m - ph, pw, ph];

            c = obj.ctl;
            x = 10; w = pw - 20; half = (w - 6)/2;
            %top-down
            y = ph - 8;
            y = y - 22; c.title.Position = [x y w 22];
            y = y - 34; c.poly.Position  = [x y w 32];
            y = y - 36; c.ell.Position   = [x y w 32];
            listTop = y - 8;
            %bottom-up
            y = 8;
            c.help.Position = [x y w 132]; y = y + 132 + 8;
            c.done.Position = [x y w 36];  y = y + 36 + 6;
            c.save.Position = [x y half 28]; c.load.Position = [x+half+6 y half 28]; y = y + 28 + 6;
            c.fit.Position  = [x y w 28];  y = y + 28 + 10;
            c.gSlider.Position = [x y w 18]; y = y + 18;
            c.gLabel.Position  = [x y w 18]; y = y + 18 + 4;
            c.bSlider.Position = [x y w 18]; y = y + 18;
            c.bLabel.Position  = [x y w 18]; y = y + 18 + 8;
            c.show.Position = [x y w 22];  y = y + 22 + 4;
            c.rename.Position = [x y half 28]; c.delete.Position = [x+half+6 y half 28]; y = y + 28 + 6;
            c.list.Position = [x y w max(listTop - y, 40)];

            if obj.isFitView || isempty(obj.viewScale)
                obj.fitView();
            else
                obj.applyView();
            end
        end

        %% display
        function D = renderImage(obj)
            gain = 1;
            gamma = 1;
            if ~isempty(obj.hBrightness) && isgraphics(obj.hBrightness)
                gain = 2^obj.hBrightness.Value;
                gamma = obj.hGamma.Value;
            end
            D = min(obj.IMscaled .* gain, 1);
            if gamma ~= 1
                D = D .^ gamma;
            end
        end

        function updateImage(obj)
            obj.hIm.CData = obj.renderImage();
        end

        function changeBrightness(obj, step)
            s = obj.hBrightness;
            s.Value = min(max(s.Value + step, s.Min), s.Max);
            obj.updateImage();
        end

        %% view (zoom and pan)
        function fitView(obj)
            [H, W, ~] = size(obj.IMscaled);
            obj.viewCenter = [(W+1)/2, (H+1)/2];
            obj.viewScale = obj.fitScale();
            obj.isFitView = true;
            obj.applyView();
        end

        function s = fitScale(obj)
            %image pixels per screen pixel that just fits the whole image
            [H, W, ~] = size(obj.IMscaled);
            axSz = obj.axesPixelSize();
            s = max(W/axSz(1), H/axSz(2));
        end

        function applyView(obj)
            %set the axes limits from viewCenter/viewScale, filling the axes
            [H, W, ~] = size(obj.IMscaled);
            obj.viewScale = min(max(obj.viewScale, 1/obj.MaxZoom), obj.fitScale());
            span = obj.axesPixelSize() .* obj.viewScale;
            c = obj.viewCenter;
            lims = [0.5 W+0.5; 0.5 H+0.5];
            for d = 1:2 %keep the image in view
                if span(d) >= diff(lims(d,:))
                    c(d) = mean(lims(d,:));
                else
                    c(d) = min(max(c(d), lims(d,1) + span(d)/2), lims(d,2) - span(d)/2);
                end
            end
            obj.viewCenter = c;
            set(obj.hAx, 'XLim', c(1) + [-1 1]*span(1)/2, 'YLim', c(2) + [-1 1]*span(2)/2);
        end

        function zoomAt(obj, p, factor)
            %factor > 1 zooms in, keeping data point p under the same screen point
            newScale = min(max(obj.viewScale / factor, 1/obj.MaxZoom), obj.fitScale());
            obj.viewCenter = p + (obj.viewCenter - p) .* (newScale / obj.viewScale);
            obj.viewScale = newScale;
            obj.isFitView = false;
            obj.applyView();
        end

        function pan(obj, dxy)
            %move the view by dxy screen pixels ([right down])
            obj.viewCenter = obj.viewCenter + dxy .* obj.viewScale;
            obj.isFitView = false;
            obj.applyView();
        end

        function sz = axesPixelSize(obj)
            pos = getpixelposition(obj.hAx);
            sz = max(pos(3:4), 1);
        end

        function p = cursorInAxes(obj)
            %data coordinates of the cursor, or [] if it is not over the axes
            cp = obj.hAx.CurrentPoint(1, 1:2);
            xl = obj.hAx.XLim; yl = obj.hAx.YLim;
            if cp(1) >= xl(1) && cp(1) <= xl(2) && cp(2) >= yl(1) && cp(2) <= yl(2)
                p = cp;
            else
                p = [];
            end
        end

        function scrollZoom(obj, ~, evt)
            p = obj.cursorInAxes();
            if isempty(p)
                return
            end
            obj.zoomAt(p, 1.25^(-evt.VerticalScrollCount));
        end

        function buttonDown(obj, src, evt)
            if strcmp(src.SelectionType, 'extend') && ~obj.isDrawing && ~isempty(obj.cursorInAxes())
                obj.panStart = {src.CurrentPoint, obj.viewCenter};
                src.WindowButtonMotionFcn = @obj.panMove;
                src.Pointer = 'fleur';
            elseif strcmp(src.SelectionType, 'normal') && ~obj.isDrawing ...
                    && isprop(evt, 'HitObject') && isequal(evt.HitObject, obj.hAx)
                obj.select(0); %a click on the background deselects
            end
        end

        function panMove(obj, src, ~)
            d = src.CurrentPoint - obj.panStart{1}; %figure pixels, y up
            obj.viewCenter = obj.panStart{2} + [-d(1), d(2)] .* obj.viewScale;
            obj.isFitView = false;
            obj.applyView();
        end

        function buttonUp(obj, src, ~)
            if ~isempty(obj.panStart)
                obj.panStart = [];
                src.WindowButtonMotionFcn = '';
                src.Pointer = 'arrow';
            end
        end

        %% keys
        function keyPress(obj, ~, evt, controlOwnsArrows)
            if nargin < 4
                controlOwnsArrows = false;
            end
            isArrow = any(strcmp(evt.Key, {'leftarrow', 'rightarrow', 'uparrow', 'downarrow'}));
            if isArrow && controlOwnsArrows
                return
            end
            step = 0.15 * obj.axesPixelSize();
            switch evt.Key
                case 'leftarrow',  obj.pan([-step(1) 0]);
                case 'rightarrow', obj.pan([step(1) 0]);
                case 'uparrow',    obj.pan([0 -step(2)]);
                case 'downarrow',  obj.pan([0 step(2)]);
                case {'equal', 'add'},       obj.zoomAt(obj.viewCenter, 1.5);
                case {'hyphen', 'subtract'}, obj.zoomAt(obj.viewCenter, 1/1.5);
                case 'f',      obj.fitView();
                case 'period', obj.changeBrightness(0.25);
                case 'comma',  obj.changeBrightness(-0.25);
                case 'h'
                    obj.hShowROIs.Value = ~obj.hShowROIs.Value;
                    obj.updateRoiVisibility();
            end
            if obj.isDrawing
                return %other keys (Esc, ...) belong to the ROI being drawn
            end
            switch evt.Key
                case {'p', 'a'}, obj.drawROI('polygon');
                case {'e', 'c'}, obj.drawROI('ellipse');
                case 'l',        obj.renameSelected();
                case {'delete', 'backspace'}, obj.deleteSelected();
            end
        end

        %% ROIs
        function drawROI(obj, kind)
            if obj.isDrawing || ~isgraphics(obj.hF)
                return
            end
            obj.isDrawing = true;
            cleanup = onCleanup(@() obj.endDrawing()); %#ok<NASGU>
            if ~obj.hShowROIs.Value %show the ROIs while drawing
                obj.hShowROIs.Value = 1;
                obj.updateRoiVisibility();
            end
            obj.select(0);
            style = obj.roiStyle();
            try
                switch kind
                    case 'polygon'
                        obj.hStatus.String = obj.PolygonHint;
                        h = drawpolygon(obj.hAx, style{:});
                    case 'ellipse'
                        obj.hStatus.String = obj.EllipseHint;
                        h = drawellipse(obj.hAx, style{:});
                end
            catch ME
                if ~isvalid(obj) || ~isgraphics(obj.hF)
                    return %the window was closed while drawing
                end
                rethrow(ME)
            end
            if ~isvalid(obj) || ~isgraphics(obj.hF)
                return
            end
            if ~isvalid(h) || ~hasGeometry(h) %drawing cancelled
                if isvalid(h)
                    delete(h);
                end
                return
            end
            obj.addROI(h);
            obj.select(numel(obj.hROIs));
            obj.endDrawing(); %restore the hint before the label dialog
            obj.setLabel(h);
        end

        function endDrawing(obj)
            if isvalid(obj)
                obj.isDrawing = false;
                if isgraphics(obj.hStatus)
                    obj.hStatus.String = obj.IdleHint;
                end
            end
        end

        function s = roiStyle(obj)
            s = {'Color', obj.RoiColor, 'FaceAlpha', 0, 'LineWidth', 1.5, 'MarkerSize', 4, ...
                'LabelAlpha', 0, 'LabelTextColor', [1 1 0.4]};
        end

        function addROI(obj, h)
            obj.roiCounter = obj.roiCounter + 1;
            h.Tag = sprintf('drawROIs_%d', obj.roiCounter);
            h.Visible = obj.hShowROIs.Value == 1;
            obj.hROIs{end+1} = h;
            obj.roiTags{end+1} = h.Tag;
            cm = h.ContextMenu;
            if ~isempty(cm)
                uimenu(cm, 'Text', 'Set Label', 'MenuSelectedFcn', @(~,~) obj.setLabel(h)); %add a 'Set Label' context menu
            end
            addlistener(h, 'ROIClicked', @(src,~) obj.select(obj.indexOf(src)));
            addlistener(h, 'ObjectBeingDestroyed', @(src,~) obj.roiDeleted(src)); %any deletion: context menu, Delete key, Load
            obj.refreshList();
        end

        function restoreROIs(obj, roiData)
            for rix = numel(obj.hROIs):-1:1
                if isvalid(obj.hROIs{rix})
                    delete(obj.hROIs{rix});
                end
            end
            obj.hROIs = {};
            obj.roiTags = {};
            obj.selectedIx = 0;
            style = obj.roiStyle();
            nSkipped = 0;
            for rix = 1:numel(roiData)
                S = roiData{rix};
                switch lower(S.Type)
                    case 'images.roi.ellipse'
                        ok = isfield(S, 'Center') && ~isempty(S.Center);
                        if ok
                            h = images.roi.Ellipse(obj.hAx, 'Center', S.Center, 'SemiAxes', S.SemiAxes, ...
                                'RotationAngle', S.RotationAngle);
                        end
                    case 'images.roi.circle'
                        ok = isfield(S, 'Center') && ~isempty(S.Center);
                        if ok
                            h = images.roi.Circle(obj.hAx, 'Center', S.Center, 'Radius', S.Radius);
                        end
                    case 'images.roi.polygon'
                        ok = isfield(S, 'Position') && ~isempty(S.Position);
                        if ok
                            h = images.roi.Polygon(obj.hAx, 'Position', S.Position);
                        end
                    otherwise
                        error('drawROIs:BadRoiType', 'bad ROI data type: %s', S.Type);
                end
                if ~ok
                    nSkipped = nSkipped + 1;
                    continue
                end
                %restore the saved properties (read-only ones are skipped), then the style
                for fnm = fieldnames(S)'
                    try
                        set(h, fnm{1}, S.(fnm{1}));
                    catch
                    end
                end
                set(h, style{:});
                h.Selected = false;
                obj.addROI(h);
            end
            if nSkipped
                warning('drawROIs:IncompleteRois', '%d incomplete ROI(s) in the file were skipped.', nSkipped);
            end
            obj.select(0);
        end

        function ix = indexOf(obj, h)
            ix = find(strcmp(obj.roiTags, h.Tag), 1);
            if isempty(ix)
                ix = 0;
            end
        end

        function roiDeleted(obj, h)
            if ~isvalid(obj)
                return
            end
            ix = obj.indexOf(h);
            if ix == 0
                return
            end
            obj.hROIs(ix) = [];
            obj.roiTags(ix) = [];
            if obj.selectedIx == ix
                obj.selectedIx = 0;
            elseif obj.selectedIx > ix
                obj.selectedIx = obj.selectedIx - 1;
            end
            if isgraphics(obj.hList)
                obj.refreshList();
            end
        end

        function select(obj, ix)
            obj.selectedIx = ix;
            for k = 1:numel(obj.hROIs)
                h = obj.hROIs{k};
                if isvalid(h)
                    if k == ix
                        set(h, 'Color', obj.SelectedColor, 'LineWidth', 2.5);
                    else
                        set(h, 'Color', obj.RoiColor, 'LineWidth', 1.5);
                    end
                end
            end
            obj.refreshList();
        end

        function refreshList(obj)
            if isempty(obj.hROIs)
                set(obj.hList, 'String', {'(no ROIs yet)'}, 'Value', [], 'Enable', 'inactive');
                return
            end
            items = cell(numel(obj.hROIs), 1);
            for k = 1:numel(obj.hROIs)
                h = obj.hROIs{k};
                label = char(h.Label);
                if isempty(label)
                    label = '<no label>';
                end
                kind = lower(regexprep(class(h), '^images\.roi\.', ''));
                items{k} = sprintf('%2d  %-16s %s', k, label, kind);
            end
            set(obj.hList, 'String', items, 'Enable', 'on', 'Value', obj.selectedIx(obj.selectedIx > 0));
        end

        function listClicked(obj, src, ~)
            if isempty(obj.hROIs) || isempty(src.Value)
                return
            end
            obj.select(src.Value(end)); %one ROI at a time
            if strcmp(obj.hF.SelectionType, 'open') %double-click
                obj.renameSelected();
            end
        end

        function renameSelected(obj)
            if obj.selectedIx > 0
                obj.setLabel(obj.hROIs{obj.selectedIx});
            end
        end

        function deleteSelected(obj)
            if obj.selectedIx > 0
                delete(obj.hROIs{obj.selectedIx}); %roiDeleted updates the list
            end
        end

        function updateRoiVisibility(obj)
            vis = obj.hShowROIs.Value == 1;
            for k = 1:numel(obj.hROIs)
                if isvalid(obj.hROIs{k})
                    obj.hROIs{k}.Visible = vis;
                end
            end
        end

        function label = suggestLabel(obj)
            %the last label with its trailing number incremented (soma1 -> soma2)
            label = 'soma1';
            for k = numel(obj.hROIs):-1:1
                last = char(obj.hROIs{k}.Label);
                if isempty(last)
                    continue
                end
                tok = regexp(last, '^(.*?)(\d+)$', 'tokens', 'once');
                if isempty(tok)
                    label = [last '2'];
                else
                    label = [tok{1} num2str(str2double(tok{2}) + 1)];
                end
                return
            end
        end
    end
end


function tf = hasGeometry(h)
%false for an ROI whose drawing was cancelled
if isa(h, 'images.roi.Ellipse') || isa(h, 'images.roi.Circle')
    tf = ~isempty(h.Center);
else
    tf = ~isempty(h.Position);
end
end


function S = roiStruct(h)
%the ROI's properties, as saved in roiData
S = get(h);
S = rmfield(S, intersect(fieldnames(S), {'Parent', 'Children', 'ContextMenu'}));
end
