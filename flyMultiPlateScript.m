function flyMultiPlateScript()

%Make sure you're running the latest version.  Download & unzip the latest from github:
%https://github.com/hepcat72/flyMultiPlate/archive/master.zip

%To estimate the time of death of each fly, download and run flyReaper:
%https://github.com/hepcat72/flyReaper/archive/master.zip

%Clear workspace so that leftover variable values do not interfere
clear;


%% experiment parameters
experimentLength             = 604800; % Length of the trial in seconds
refStackSize                 = 11;     % Number of reference images
refStackUpdateTiming         = 10;     % How often to update a ref image (secs)
writeToFileTiming            = 20;     % How often to write out data
wellToWellSpacing_mm         = 8;      % distance between wells in mm
pauseBetweenAcquisitions_sec = 0.01;   % pause between subsequent images

%fly position extraction parameters
trackingThreshold            = 10;     % higher = smaller regs detected as diff

%% Plate type parameters
askPlateType           = 1;
plateType              = 0;  %Type 0 = 96 wells, type 1 = 24 wells
nCols                  = 12; %Reset for plateType
nRows                  = 8;
ROIfactor96            = 1.8; %Determines well radius by dividing the well
ROIfactor24            = 2.0; %sapcing by this factor, which is different
                              %per plate type. 96 well plate=1.8. 24 well
                              %plate=2.0 (because wells are closer
                              %together, relatively speaking)


%% video backup parameters (ignored when in fileMode)
askMakeBackupVideo     = 0; %0 = use makeBackupVideoDefault, 1 = true
makeBackupVideoDefault = 1; %0 = false, 1 = true
askVidFormat           = 1; %0 = use vidFormatDefault, 1 = true
vidFormatDefault       = 'Archival'; %Options = 'Motion JPEG 2000',
                                     %          'Archival',
                                     %          'Motion JPEG AVI','MPEG-4'
                                     %          'Uncompressed AVI'
vidExtensionDefault    = '.mj2'; %Must match vidFormatDefault (avi,mj2,mp4)
askFPS                 = 0;  %Not used unless manual frame rate setting
                             %fails
fpsDefault             = 60; %Cannot change this (should get from camera)
overlayTimestamp       = 1;  %Overlays a timestamp and frame number in the
                             %top right of the backup video. Note, if this
                             %overlaps any wells, re-analysis of those
                             %wells will be compromised
overlayFormat          = 'dd-mmm-yyyy HH:MM:SS.FFF';
overlayTextColor       = 'white';


%% fileMode options (ignored when not in fileMode)
askShowPlayback        = 1;
showPlayback           = 0;
pingTiming             = 60; %How often (in expmnt time) to show message (secs)
askUseSavedWells       = 1;
useSavedWells          = 1;

%% initialization
debug_memory           = 0;                    % NOTE: Does not work on mac
if debug_memory == 1
    [user, ~]          = memory;
    initialMemory      = user.MemUsedMATLAB;
end
usageTiming            = 60;
lastUsageTime          = 0;
datetimeFormat         = 'dd-MMM-uuuu HH:mm:ss.SSSSSSSSS';
datetimeSpec           = ['%{',datetimeFormat,'}D']; %For file reading
lastRefStackUpdateTime = 0;
makeBackupVideo        = makeBackupVideoDefault;
vidFormat              = vidFormatDefault;
vidExtension           = vidExtensionDefault;
fps                    = fpsDefault;
maxFPS                 = 60;  %Cannot change this (should get from camera)
percentFPS             = 100; %This is always used if possible
askUseAllCams          = 1;   %0 = use all, 1 = ask which cams to use
lastPingTime = -1;


close all;


if verLessThan('matlab','9.1')
    error('Matlab R2016b or higher is required.')
    return;
end


%If no cam is plugged in, offer to process a saved video file
fileMode = 0;
choice = questdlg('Would you like to process a video file or live camera?',...
                  'Warning','File','Camera','Camera');
if strcmp(choice, 'File')
    fileMode = 1;
end


%% Select the camera(s) to use
nCamsToUse    = 1;
selectedCam   = 1;
camsToUse     = [selectedCam];
if fileMode == 0

    camsInfo      = imaqhwinfo('pointgrey');
    pause(1);
    % The following assumes all the cameras we're going to use record in
    % the same format
    defCamFormat  = camsInfo.DeviceInfo.DefaultFormat;
    cams          = camsInfo.DeviceIDs;

    %See if we are going to be saving a backup video file
    if askMakeBackupVideo == 1
        def = 'Yes';
        alt = 0;
        if makeBackupVideo == 0
            def = 'No';
            alt = 1;
        end
        choice = questdlg('Would you like to save a backup video file?',...
                          'Backup option','No','Yes',def);
        if not(strcmp(choice, def))
            makeBackupVideo = alt;
        end
    end

    %Get the frames per second rate at which to save the backup (note, this
    %affects real-time processing too)
    if makeBackupVideo == 1 && askFPS == 1
        [percentFPS,fps] = fpsdlg(maxFPS,experimentLength);
    else
        percentFPS = (fps / maxFPS) * 100;
    end

    %Determine the format the backup will be saved in
    if makeBackupVideo == 1 && askVidFormat == 1
        [vidExtension,vidFormat] = selectFiletype(fps);
    end

    %If there's more than 1 camera connected determine how many the user wants
    %to use in this run
    if numel(cams) > 1
        if askUseAllCams == 1
            nCamsToUse = getNumListDialog('How many cameras?',...
                                          1:numel(cams));
            if nCamsToUse < numel(cams)
                camsToUse   = [];
                for nextCam = 1:nCamsToUse
                    ok = 0;
                    while ok == 0
                        [selection, ok] = listdlg('PromptString',...
                                                  'Select PointGrey Camera',...
                                                  'SelectionMode','single',...
                                                  'InitialValue',selectedCam,...
                                                  'ListString',...
                                                  cellfun(@num2str,cams)');
                    end
                    selectedCam = cams{1,selection};
                    camsToUse = [camsToUse selectedCam];
                end
            else
                camsToUse = 1:nCamsToUse;
            end
        else
            nCamsToUse = numel(cams);
            camsToUse  = 1:numel(cams);
        end
    elseif numel(cams) == 0
        choice = questdlg('No camera detected.  Read video from file?',...
                          'Warning','Yes','No','No');
        if strcmp(choice, 'No')
            return;
        end
        fileMode = 1;
    end

    %% Clear out any previous camera settings (unless other cameras may
    %% already be in use - so we don't disrupt their possible use in other
    %% concurrent runs)
    if nCamsToUse == numel(cams)
        imaqreset;
    end
else
    if askUseSavedWells == 1
        defChoice = 2;   %'Saved Originals';
        if useSavedWells == 0
            defChoice = 1;   %'New';
        end

        ok = 0;
        while ok == 0
            [useSavedWells, ok] = listdlg('PromptString',...
                                      [{'Use/tweak saved well positions or choose new ones for a technical replicate?'} {''} {''}],...
                                      'SelectionMode','single',...
                                      'ListSize',[200 80],...
                                      'InitialValue',defChoice,...
                                      'ListString',...
                                      [string('New'),string('Saved Originals'),string('Tweak Originals'),string('Saved Other'),string('Tweak Other')]);
        end
        %choice = questdlg('Use/tweak saved well positions or choose new ones for a technical replicate?',...
        %                  'Wells Positions Choice','New','Tweak Originals','Tweak Other','Saved Originals','Saved Other',...
        %                  defChoice);
        %0=new wells, 1=Saved Originals, 2=Tweak Originals, 3=Saved Other,
        %4=Tweak Other
        useSavedWells = useSavedWells - 1;
    end

    if askShowPlayback == 1
        defChoice = 'Console Status Only';
        if showPlayback == 1
            defChoice = 'Live Playback';
        end

        choice = questdlg('Live playback during reprocessing (slower)?',...
                          'Playback','Live Playback','Console Status Only',...
                          defChoice);
        if strcmp(choice, 'Live Playback')
            showPlayback = 1;
        else
            showPlayback = 0;
        end
    end
end



%% Variables needed to keep time & hold vids/images
counter  = 1;
tElapsed = 0;
tc       = 1;
vids     = []; % Matrix of camera video connections
ims      = []; % Matrix of images


%If we're processing a video file
if fileMode == 1

    %Going to use nCamsToUse, selectedCam, and camsToUse as number of vids to
    %use, vid num, and vids to use
    %HOWEVER - Only going to support processing 1 vid at a time (in case they
    %are different lengths or frames per sec)

    %% Open the video file

    %Prompt the user to open a video file
    disp('Select a video file for processing')
    [fileName,pathName] = uigetfile({'*.mj2;*.avi;*.mp4;*.m4v'; ...
                                     '*.mj2';'*.avi';'*.mp4';'*.m4v'},...
                                    'Process previously saved video');

    vidObj = VideoReader(fullfile(pathName,fileName));

    %Determine the length of the experiment in seconds (since that was
    %predetermined and may be different from what this script sets as default
    %above).
    %%THIS IS NOT USED BECAUSE IT IS BASED ON FRAME RATE WHICH IS VARIABLE
    experimentLength = vidObj.Duration;

    %vidHeight = vidObj.Height;
    %vidWidth = vidObj.Width;

    %Put the video object in the 'Matrix of camera video connections' since
    %that's how we obtain frames
    camIdx = 1;
    vids{camIdx} = vidObj;

    %Create a MATLAB® movie structure array
    %ims{camIdx} = struct('cdata',zeros(vidHeight,vidWidth,3,'uint8'),...
    %                     'colormap',[]);

    %% Open the timestamp file

    %Get the timestamp file - do all the possible replacements to brute-force
    %finding the filename
    timestampFileName = strrep(fileName,'.mj2','-timestamps.csv');
    timestampFileName = strrep(timestampFileName,'.avi','-timestamps.csv');
    timestampFileName = strrep(timestampFileName,'.mp4','-timestamps.csv');
    timestampFileName = strrep(timestampFileName,'.m4v','-timestamps.csv');

    curFolder = pwd;

    %Check the existence of the associated timstamp file
    cd(pathName);
    if not(exist(timestampFileName,'file') == 2)
        msg = sprintf('Select the timestamp file associated with: %s',fileName)
        disp(msg)
        [timestampFileName,timestampPathName] = uigetfile({'*.csv'},msg);
    else
        timestampPathName = pathName;
    end

    if useSavedWells > 0

        %% Find the well positions file

        % Assume the well positions file is in the same place as the timestamps file
        wellposesFileName = strrep(timestampFileName,'-timestamps.csv','-wellposes.mat');
        wellposesPathName = timestampPathName;

        %Check the existence of the associated wellposes file
        if useSavedWells > 2 || not(exist(fullfile(wellposesPathName,wellposesFileName),'file') == 2)
            disp('Select well positions for each plate. Assuming horizontally positioned plates, click the top-left and bottom-left wells.')
            [wellposesFileName,wellposesPathName] = uigetfile({'*.mat'},strcat('Select the well positions file associated with: ',fileName));
        end

        %Load the wellposes mat file (temp variables we'll use later)
        load(fullfile(wellposesPathName,wellposesFileName))
        
    end

    cd(curFolder);

    disp(strcat('Opening timestamp file: ',fullfile(timestampPathName,...
                                                    timestampFileName)))
    timestampTable = readtable(fullfile(timestampPathName,...
                                        timestampFileName),...
                               'Delimiter',',','Format',datetimeSpec,...
                               'ReadVariableNames',false);
    [numTimestamps, ~] = size(timestampTable);

    %Create a filename stub for all the output files
    fileName = strrep(timestampFileName,'-timestamps.csv',['-reanalysis',datestr(now,'yyyymmdd-HHMMSS')]);
else
    %Prompt the user to create a base outfile name
    [fileName, pathName] = uiputfile([datestr(now,'yyyymmdd-HHMMSS'),'.csv'],...
                                     'Create a base output file name');
    fileName = strrep(fileName,'.csv','');
end


%% Prepare the output data files

for camIdx = 1:nCamsToUse
    tmpFileName = fileName;
    if fileMode == 0
        tmpFileName = strcat(fileName,'-cam',num2str(camsToUse(camIdx)));
    end

    fileNameCentroidPosition{camIdx} = strcat(tmpFileName,'centroidPos.csv');
    fileNameCentroidSize{camIdx}     = strcat(tmpFileName,'centroidSize.csv');
    fileNameInstantSpeed{camIdx}     = strcat(tmpFileName,'instantSpeed.csv');
    fileNameDispTravel{camIdx}       = strcat(tmpFileName,'displacementTravel.csv');
    fileNameTotalDistTravel{camIdx}  = strcat(tmpFileName,'totalDistTravel.csv');

    if fileMode == 0 && makeBackupVideo == 1
        fileNameBackupVid{camIdx}    = strcat(tmpFileName,vidExtension);
        fileNameBackupTimes{camIdx}  = strcat(tmpFileName,'-timestamps.csv');
        % The following will end up with a .mat extension appended
        fileNameBackupWells{camIdx}  = strcat(tmpFileName,'-wellposes');
    elseif useSavedWells == 0 || useSavedWells == 2 || useSavedWells == 4
        fileNameBackupWells{camIdx}  = strcat(tmpFileName,'-wellposes');
    end

    %% get file ready for writing
    fidA{camIdx} = fopen(fullfile(pathName,fileNameCentroidPosition{camIdx}),'w'); % done
    fidB{camIdx} = fopen(fullfile(pathName,fileNameCentroidSize{camIdx}),    'w'); % needs testing
    fidC{camIdx} = fopen(fullfile(pathName,fileNameInstantSpeed{camIdx}),    'w'); % needs testing
    fidD{camIdx} = fopen(fullfile(pathName,fileNameDispTravel{camIdx}),      'w'); % needs testing
    fidE{camIdx} = fopen(fullfile(pathName,fileNameTotalDistTravel{camIdx}), 'w'); % needs testing

    if fileMode == 0 && makeBackupVideo == 1
        %The video file will be created by VideoWriter
        fidT{camIdx} = fopen(fullfile(pathName,fileNameBackupTimes{camIdx}), 'w');
    end

    fprintf(fidA{camIdx},'time_sec,');
    fprintf(fidB{camIdx},'time_sec,');
    fprintf(fidC{camIdx},'time_sec,');
    fprintf(fidD{camIdx},'time_sec,');
    fprintf(fidE{camIdx},'time_sec,');
end
fileNameMemUsage = strcat(fileName,'-memUsage.log');
fidG = fopen(fullfile(pathName,fileNameMemUsage),'w');


%% Adjust the brightness, contrast, focus, & alignment of the cameras

if fileMode == 0
    disp(['Adjust the camera brightness, contrast, focus, alignment, and position (to avoid overlap with the overlayTimestamp)'])
    disp(['Note, you can turn the overlayTimestamp variable off or change the overlayTextColor by editing and re-running this script'])
    loadedvids = 0;
    while loadedvids == 0
        for camIdx = 1:nCamsToUse
            nPlates{camIdx} = 0;
            selectedCam = camsToUse(camIdx);
            pause(1);
            % Video inputs; depends on the type of camera used

            try
                vids{camIdx} = videoinput('pointgrey',selectedCam,'F7_BayerRG8_664x524_Mode1');
                loadedvids = 1;
            catch ME
                try
                    %pointgrey's format_7 must not be available, so go with
                    %the camera's default
                    vids{camIdx} = videoinput('pointgrey',selectedCam,defCamFormat);
                    loadedvids = 1;
                    disp('WARNING: Unable to use default camera output format.  Setting static format of F7_BayerRG8_664x524_Mode1')
                catch
                    loadedvids = 0;
                    choice = questdlg(['Camera ' num2str(camIdx) ' is in use.  Would you like to reset all cameras and continue?'],...
                                       'Warning','Yes','No','No');
                    if strcmp(choice, 'No')
                        return;
                    end
                    imaqreset;
                    break;
                end
            end
            pause(1);
        end
    end

    for camIdx = 1:nCamsToUse

        src = getselectedsource(vids{camIdx});
        triggerconfig(vids{camIdx},'manual');
        vids{camIdx}.TriggerRepeat = Inf;

        set(vids{camIdx},'ReturnedColorSpace','rgb');

        % Set all parameters to manual and define the best set
        src.Brightness              = 0;
        src.ExposureMode            = 'Manual';
        src.Exposure                = 1;
        try
            src.FrameRatePercentageMode = 'Manual';
            src.FrameRatePercentage     = percentFPS;
        catch
            %pointgrey format_7 must not be available
            src.FrameRate               = fps;
            disp('WARNING: Unable to set FrameRatePercentageMode to manual');
        end
        src.GainMode                = 'Manual';
        src.Gain                    = 0;
        src.ShutterMode             = 'Manual';
        src.Shutter                 = 8;
        src.WhiteBalanceRBMode      = 'Off';
    
        disp(['Camera ' num2str(camIdx) ' seetings: '])
        %Confirm all the camera settings to the user
        get(getselectedsource(vid))

        %% start by previewing the image to adjust alignment and focus

        try
            start(vids{camIdx});
        catch ME
        end

        fig1 = figure();
        while ishghandle(fig1)

            pause(0.01);
            im = (peekdata(vids{camIdx},1));

            try
                im = rgb2gray(im);
                if overlayTimestamp > 0
                    im = insertText(im,[0 0],...
                        [overlayFormat ' Frame: ##########'],...
                        'BoxOpacity',0.0,'TextColor',overlayTextColor);
                end
                imshow(im,[],'i','f');
                drawnow;
                title(['preview cam ' num2str(selectedCam) ': adjust contrast/focus/brightness']);
                pause(0.01);
            end
        end
        close(gcf); % Closes the plot/image

        %Save a frame so we can use it to find the well positions
        ims{camIdx} = (peekdata(vids{camIdx},1));
        ims{camIdx} = rgb2gray(ims{camIdx});
    end
else
    %Retrieve a frame in order to allow manual positioning of the wells for
    %technical replicates.  We will also set the initial timestamp while
    %we're at it.
    %Note - Can only process 1 video file at a time
    nCamsToUse = 1;
    camIdx     = 1;
    if(hasFrame(vids{camIdx}))
        disp('Retrieving initial frame')
        ims{camIdx} = double(readFrame(vids{camIdx})) / 255.0;
        ims{camIdx} = rgb2gray(ims{camIdx});

        timestampIndex = 1;
        curTimestamp{camIdx} = timestampTable{timestampIndex,1};
        initialTime{camIdx} = curTimestamp{camIdx};
        msg = sprintf('Initial Timestamp from video: %s',initialTime{camIdx});
        disp(msg)
    end
end

%% find the circular features and establish where the wells are
for camIdx=1:nCamsToUse

    wellPosesChanged = 0;
    if useSavedWells > 0 && fileMode == 1
        disp('Restoring saved well positions. Edit individual well positions by click & arrow keys. Close woindow when finished.')

        % These vars were loaded above with load(wellposesFileName)
        % Note: when fileMode == 1, nCamsToUse is expected to be 1 (can only process 1 vid file at a time (currently))
        wellCoordinates{camIdx} = savedWellCoords;
        wellSpacingPix{camIdx}  = savedWellSpacing;
        ROISize{camIdx}         = savedROIs;
        nPlates{camIdx}         = savedNPlates;
        %For backwards compatibility when this only worked with 96 well
        %plates
        if not(exist('savedPlateType'))
            plateType = 0;
        else
            plateType = savedPlateType;
        end

        if plateType == 0
            nCols = 12;
            nRows = 8;
            ROIfactor = ROIfactor96;
        else
            nCols = 6;
            nRows = 4;
            ROIfactor = ROIfactor24;
        end
        
        %To debug a file with a saved ROISize that's no good
        %ROISize{camIdx} = round(wellSpacingPix{camIdx} / ROIfactor);

        if useSavedWells == 2 || useSavedWells == 4
            %% Allow the user to tweak well positions
            %This is mainly to confirm the saved wells were accurate
            wellCoordinates{camIdx} = repositionCrosses(ims{camIdx},...
                                                        wellCoordinates{camIdx},...
                                                        ROISize{camIdx}*2+1);
            wellPosesChanged = 1;
        end

    else
        if askPlateType == 1
            def = '96';
            alt = 1;
            if plateType == 1
                def = '24';
                alt = 0;
            end
            choice = questdlg('Select plate type',...
                              'Number of wells per plate','24','96',def);
            if not(strcmp(choice, def))
                plateType = alt;
            end
        end

        if plateType == 0
            nCols = 12;
            nRows = 8;
            ROIfactor = ROIfactor96;
        else
            nCols = 6;
            nRows = 4;
            ROIfactor = ROIfactor24;
        end

        [x2{camIdx},positionParameters{camIdx}] = findwells(camsToUse(camIdx),...
                                                            ims{camIdx},...
                                                            plateType);

        wellPosesChanged = 1;

        % include a little more than half the interwell spacing in each "well" 
        % this is a little more forgiving when it comes to the placement of the
        % well in the GUI

        nPlates{camIdx} = numel(positionParameters{camIdx});

        %Average the well spacing for all plates in the image
        wellSpacingPix{camIdx} = 0;
        for iiPlate = 1:nPlates{camIdx}
            wellSpacingPix{camIdx}=wellSpacingPix{camIdx}+ abs((positionParameters{camIdx}{iiPlate}(4)));
        end
        wellSpacingPix{camIdx} = wellSpacingPix{camIdx}/nPlates{camIdx};
        ROISize{camIdx}        = round(wellSpacingPix{camIdx}/ROIfactor);

        %% move well coordinates into the proper shape
        x2{camIdx} = (x2{camIdx}');    
        wellCoordinates{camIdx} = round(x2{camIdx});
    
        %% Allow the user to move specific wells after the gross positioning
        wellCoordinates{camIdx} = repositionCrosses(ims{camIdx},...
                                                    wellCoordinates{camIdx},...
                                                    ROISize{camIdx}*2+1);

    end

    %Save the well position data to .mat files for each camera
    if wellPosesChanged == 1
        %Create temporary variables to save
        savedWellCoords  = wellCoordinates{camIdx};
        savedWellSpacing = wellSpacingPix{camIdx};
        savedROIs        = ROISize{camIdx};
        savedNPlates     = nPlates{camIdx};
        savedPlateType   = plateType;
        save(fullfile(pathName,fileNameBackupWells{camIdx}),'savedWellCoords','savedWellSpacing','savedROIs','savedNPlates','savedPlateType');
    end

    %% write out positions and header information
    for jjPlate = 1:nPlates{camIdx}
        for jjCol = 1:nCols
            for jjRow = 1:nRows
                wellName = ['cam:',num2str(camsToUse(camIdx)),'_plate:',num2str(jjPlate),'_well:',...
                            char(64+jjRow),num2str(jjCol)];
                fprintf(fidA{camIdx},[wellName, '_x,', wellName, '_y,']);
                fprintf(fidB{camIdx},[wellName, '_size,']);
                fprintf(fidC{camIdx},[wellName, '_speed(mm/s),']);
                fprintf(fidD{camIdx},[wellName, '_displacement(mm),']);
                fprintf(fidE{camIdx},[wellName, '_distance(mm),']);
            end
        end
    end

    fprintf(fidA{camIdx},'\r\n');
    fprintf(fidB{camIdx},'\r\n');
    fprintf(fidC{camIdx},'\r\n');
    fprintf(fidD{camIdx},'\r\n');
    fprintf(fidE{camIdx},'\r\n');
    
    % start the camera if it is not already started
    try
        start(vids{camIdx});
    catch ME
    end

end

%tic/toc is only used to track real time running time in fileMode
startTime = tic;

if debug_memory == 1
    %Print column headers for memory usage output
    msg = ['Secs',char(9),'Mb Added Since Start'];
    disp(msg)
    fprintf(fidG, '%s\n', msg);
end

%% run experiment

% for faster updating of the images, display images using Cdata instead of a
% full call to imshow or image
imshowHand = nan;

%Initialize the outCentroids & outDisplaements matrices and output frameNum
for camIdx=1:nCamsToUse
    frameNum{camIdx}         = 0;
    outCentroids{camIdx}     = [];
    outDisplacements{camIdx} = [];
end

%If we are backing up videos, stop & start back up with recording enabled
%SAVING A VIDEO IS NOT YET TESTED FOR MULTIPLE CAMERAS
if fileMode == 0 && makeBackupVideo == 1

    for camIdx=1:nCamsToUse
        stop(vids{camIdx});
    end

    for camIdx=1:nCamsToUse

        triggerconfig(vids{camIdx},'Manual');

        %Open a video file to write to
        diskLoggers{camIdx} = ...
            VideoWriter(fullfile(pathName,...
                        fileNameBackupVid{camIdx}),...
                        vidFormat);
        open(diskLoggers{camIdx});

        start(vids{camIdx});
    end
    
    % create a clean up object to create usable video files upon ctrl-c
    cleanupObj = onCleanup(@() cleanUpVids(vids,diskLoggers,fidT,nCamsToUse));
end

%Retrieve and record a frame from the live camera in order to initialize
%the first reference image, put it on the refStack, and set the
%initialTime.  This was already done for fileMode (in order to get a frame
%to position the wells).
if fileMode == 0

    for camIdx=1:nCamsToUse

        triggerTries = 5;
        worked = 0;

        while triggerTries > 0 && worked == 0
            %Trigger the acquisition of a frame
            trigger(vids{camIdx});
            try
                %Wait for single frame acquisition to finish
                wait(vids{camIdx},1,'logging');
                worked = 1;
            catch
                worked = 0;
                tries = 0;
                maxtries = 11;
                while worked == 0 && tries < maxtries
                    disp('WARNING: Frame acquisition is taking longer than expected')
                    try
                        wait(vids{camIdx},1,'logging');
                        worked = 1;
                    catch
                        tries = tries + 1;
                    end
                end
                if tries == maxtries && worked == 0
                    disp('Could not get frame. Skipping and attempting to start over...')
                    triggerTries = triggerTries - 1;
                    continue;
                else
                    disp('Frame recovered')
                end
            end

            %Retrieve/remove the acquired image from the buffer
            [ims{camIdx},curTimestamp{camIdx}] = ...
                getFrameData(vids{camIdx},datetimeFormat);
            %Probably unnecessary - nothing else should get in the buffer
            flushdata(vids{camIdx});
            %Set the image to be written to the video backup file
            writeImage = ims{camIdx};
            frameNum{camIdx} = frameNum{camIdx} + 1;
            if overlayTimestamp > 0
                writeImage = insertText(writeImage,[0 0],...
                    [datestr(curTimestamp{camIdx},overlayFormat)...
                        ' Frame: ' num2str(frameNum{camIdx})],...
                        'BoxOpacity',0.0,'TextColor',overlayTextColor);
            end
            %Write the frame to the video file
            writeVideo(diskLoggers{camIdx},writeImage);
            %Write the timestamp for the frame for use in later processing
            fprintf(fidT{camIdx},'%s\r\n',curTimestamp{camIdx});

            %Depending on what method is used to get the current image, you
            %may need to multiply by 255
            ims{camIdx} = round(rgb2gray(ims{camIdx}));
            ims{camIdx} = double(ims{camIdx});

        end

        if worked == 0
            msg = sprintf('Unable to initialize the reference image stack because camera %s is not responding.',camIdx);
            disp(msg)
            return;
        end
    end

    %We're going to arbitrarily use the last camer'a frame timestamp as the
    %initial time
    initialTime{camIdx} = curTimestamp{camIdx};
end

%Initialize the tElapsed and the first reference image and put it on the
%refStack for each camera
for camIdx=1:nCamsToUse

    tElapsedCam{camIdx}=0;
    refStacks{camIdx}=double(ims{camIdx});
    refImages{camIdx}=median(refStacks{camIdx},3);

end

%The experiment duration derived from the saved video file is unreliable
%because it is based on a static inaccurate frame rate of a manual variable
%frame rate video, so we are using a different means in the while loop
%expression for fileMode to determine when to stop (namely: hasFrame).
notDone = 1;
if fileMode == 1
    disp('Starting re-analysis')
    %Assumption: If hasFrame returned true, timestampIndex will be 1
    notDone = timestampIndex;
end

while notDone
    % grab the most recent frame from the cameras and convert to a single
    % grayscale image
    for camIdx=1:nCamsToUse
        if fileMode == 0

            %Trigger the acquisition of a frame
            trigger(vids{camIdx});
            try
                %Wait for single frame acquisition to finish
                wait(vids{camIdx},1,'logging');
            catch
                worked = 0;
                tries = 0;
                maxtries = 11;
                while worked == 0 && tries < maxtries
                    disp('WARNING: Frame acquisition is taking longer than expected')
                    try
                        wait(vids{camIdx},1,'logging');
                        worked = 1;
                    catch
                        tries = tries + 1;
                    end
                end
                if tries == maxtries && worked == 0
                    disp('Could not get frame. Skipping and attempting to start over...')
                    continue;
                else
                    disp('Frame recovered')
                end
            end
                    
            %Retrieve/remove the acquired from the buffer
            [ims{camIdx},curTimestamp{camIdx}] = getFrameData(vids{camIdx},datetimeFormat);
            %Probably unnecessary - nothing else should get in the buffer
            flushdata(vids{camIdx});
            %Set the image to be written to the video backup file
            writeImage = ims{camIdx};
            frameNum{camIdx} = frameNum{camIdx} + 1;
            if overlayTimestamp > 0
                writeImage = insertText(writeImage,[0 0],...
                    [datestr(curTimestamp{camIdx},overlayFormat)...
                        ' Frame: ' num2str(frameNum{camIdx})],...
                        'BoxOpacity',0.0,'TextColor',overlayTextColor);
            end
            %Write the frame to the video file
            writeVideo(diskLoggers{camIdx},writeImage);
            %Write the timestamp for the frame for use in later processing
            fprintf(fidT{camIdx},'%s\r\n',curTimestamp{camIdx});

            %Depending on what method is used to get the current image, you
            %may need to multiply by 255
            %ims{camIdx} = round(rgb2gray(ims{camIdx})*255);
            ims{camIdx} = round(rgb2gray(ims{camIdx}));
            ims{camIdx} = double(ims{camIdx});
        else
            if(hasFrame(vids{camIdx}))
                ims{camIdx} = double(readFrame(vids{camIdx})) / 255.0;
                ims{camIdx} = rgb2gray(ims{camIdx});

                timestampIndex = timestampIndex + 1;
                if timestampIndex > numTimestamps
                    %PRINT ERROR
                    msg = sprintf('ERROR: There are not as many timestamps (total %i) as there were frames in the video (at least %i). Unable to proceed.',numTimestamps,timestampIndex);
                    disp(msg)
                    notDone = 0;
                    break;
                end
                curTimestamp{camIdx} = timestampTable{timestampIndex,1};
                notDone = 1;
            %If the elapsed time is less than the exp. length (minus 1 sec
            %leeway)
            elseif tElapsedCam{camIdx} < (experimentLength - 1)
                %PRINT WARNING
                msg = sprintf('WARNING: The video file seems to have ended (at %d) before the duration it claimed it was at the beginning (%d).  This is OK, if the time processed thus far seems to be adequate.',tElapsedCam{camIdx},experimentLength);
                disp(msg)
                notDone = 0;
                break;
            else
                notDone = 0;
                break;
            end

            ims{camIdx} = round(ims{camIdx}*255);
            ims{camIdx} = double(ims{camIdx});
        end
        %In fileMode, we already have an image to process at the beginning
        %of the loop and it's the one corresponding to the current tElapsed
        %Therefor, the next frame is retrieved at the end of the loop

        tElapsedCam{camIdx} = etime(datevec(curTimestamp{camIdx}),datevec(initialTime{camIdx}));

        %We're going to keep the last one as our global reference for
        %deciding whether to continue looping and other timed events
        tElapsed = tElapsedCam{camIdx};
    end

    if debug_memory == 1
        %Log the memory usage once every "usageTiming" seconds (accounts for
        %loop taking too long & an interval is skipped)
        if lastUsageTime == 0 || tElapsed >= (lastUsageTime + usageTiming)
            [user, ~] = memory;
            memoryAddedSinceStartMB = (user.MemUsedMATLAB - initialMemory)/1000000;
            msg = sprintf('%i%s%i', round(tElapsed), char(9),...
                          round(memoryAddedSinceStartMB));
            disp(msg)
            fprintf(fidG, '%s\n', msg);
            lastUsageTime = tElapsed;
        end
    end

    % check to see if the reference stack requires updating
    % detect every ref frame update
    if tElapsed >= (lastRefStackUpdateTime + refStackUpdateTiming)
        %disp(['Updating refStack at time ' num2str(tElapsed)])
        for camIdx = 1:nCamsToUse
            refStack = refStacks{camIdx};
            % if current ref images size reaches the refstacksize defined above
            if size(refStacks{camIdx},3) == refStackSize
                % Replace the last ref image with the new one
                refStacks{camIdx}=cat(3,refStack(:,:,2:end),ims{camIdx});
            else
                refStacks{camIdx}=cat(3,refStack,ims{camIdx});
            end
            % the ref image displayed is the median image of the refstack
            refImages{camIdx}=median(refStack,3);
        end
        lastRefStackUpdateTime = tElapsed;
    end
    
    %calculate fly positions every frame
    if exist('refImages','var')
        displayIm = [];
        spacer=zeros((ROISize{camIdx}*2+2)*(nRows+1),ROISize{camIdx}+1,3)+255;
        for camIdx = 1:nCamsToUse
            tempIms{camIdx}=zeros((ROISize{camIdx}*2+2)*(nRows+1),(ROISize{camIdx}*2+2)*(nPlates{camIdx}*nCols+1),3)+255;
            centroidsTemp{camIdx}=zeros(size(wellCoordinates{camIdx},1),2);
        
            diffIms{camIdx}=(refImages{camIdx}-double(ims{camIdx}));
        
            for iiWell=1:size(wellCoordinates{camIdx},1)
                diffImsSmall{camIdx} = diffIms{camIdx}(wellCoordinates{camIdx}(iiWell,2)+(-ROISize{camIdx}:ROISize{camIdx}),...
                                                       wellCoordinates{camIdx}(iiWell,1)+(-ROISize{camIdx}:ROISize{camIdx}));

                diffImsSmall{camIdx}=255*(diffImsSmall{camIdx}>trackingThreshold);

                bkImsSmall{camIdx}=ims{camIdx}(wellCoordinates{camIdx}(iiWell,2)+(-ROISize{camIdx}:ROISize{camIdx}),...
                                               wellCoordinates{camIdx}(iiWell,1)+(-ROISize{camIdx}:ROISize{camIdx}));

                % build up an image for display purposes
                tempIms{camIdx}( (mod(iiWell-1,nRows))*(ROISize{camIdx}*2+2)+(ROISize{camIdx}:3*ROISize{camIdx}),...
                        (((iiWell-1)-mod(iiWell-1,nRows))/nRows)*(ROISize{camIdx}*2+2)+(ROISize{camIdx}:3*ROISize{camIdx}),...
                        2) = ...
                        bkImsSmall{camIdx};

                tempIms{camIdx}( (mod(iiWell-1,nRows))*(ROISize{camIdx}*2+2)+(ROISize{camIdx}:3*ROISize{camIdx}),...
                        (((iiWell-1)-mod(iiWell-1,nRows))/nRows)*(ROISize{camIdx}*2+2)+(ROISize{camIdx}:3*ROISize{camIdx}),...
                        3) = ...
                        bkImsSmall{camIdx};

                tempIms{camIdx}( (mod(iiWell-1,nRows))*(ROISize{camIdx}*2+2)+(ROISize{camIdx}:3*ROISize{camIdx}),...
                        (((iiWell-1)-mod(iiWell-1,nRows))/nRows)*(ROISize{camIdx}*2+2)+(ROISize{camIdx}:3*ROISize{camIdx}),...
                        1) = ...
                        diffImsSmall{camIdx};

                % calculate the center of mass of the thresholded
                % difference map
                xCentroid=sum(diffImsSmall{camIdx},1);
                xCentroid=sum(xCentroid.*(1:2*ROISize{camIdx}+1))/sum(xCentroid);
                yCentroid=sum(diffImsSmall{camIdx},2);
                yCentroid=sum(yCentroid'.*(1:2*ROISize{camIdx}+1))/sum(yCentroid);
                centroidsTemp{camIdx}(iiWell,:)=[xCentroid yCentroid];
                centroidsSizeTemp{camIdx}(iiWell)=[nnz(diffImsSmall{camIdx})];
            end
      
            % saturate the image slightly for display purposes;
            tempIms2{camIdx}                      = tempIms{camIdx}./255;
            tempIms2{camIdx}                      = tempIms2{camIdx}-0.02;
            tempIms2{camIdx}(tempIms2{camIdx}>.2) = 0.1;
            tempIms2{camIdx}(tempIms2{camIdx}<0)  = 0;
            tempIms2{camIdx}                      = tempIms2{camIdx}./0.2;

            %Create an image to display
            if camIdx == 1
                displayIm = [displayIm;tempIms2{camIdx}];
            else
                %The following takes tempIms2{camIdx}, which is a series of
                %plate images displayed horizontally (for a specific camera)
                %'camIdx' and tacks on a row of plates for each camera.  Any
                %odd width differences in the camera images are handled by
                %filling in zeros.
                [h1 w1 ~] = size(displayIm);
                [h2 w2 ~] = size(tempIms2{camIdx});
                tDisplayIm = displayIm;
                tNewIm = tempIms2{camIdx};
                if w1 > w2
                    tNewIm = [tNewIm zeros(h2,w1-w2,3)];
                elseif w2 > w1
                    tDisplayIm = [tDisplayIm zeros(h1,w2-w1,3)];
                    displayIm = tDisplayIm;
                end
                displayIm = [displayIm;tNewIm];
            end
        end

        %Display the processed video
        if fileMode == 0 || showPlayback == 1
            % display the image
            if not(ishghandle(imshowHand))
                imshowHand = imshow(displayIm,[],'initialMag','fit',...
                                    'Border','tight');
            else
                set(imshowHand,'Cdata',displayIm);
            end
        end

        %Report on progress or re-analysis
        if debug_memory == 0 && (lastPingTime == -1 || tElapsed >= (lastPingTime + pingTiming))
            if fileMode == 1
                realtime = toc(startTime);
                msg = sprintf('Elapsed Experiment Time: %i seconds  Real time: %i seconds',...
                              round(tElapsed), round(realtime));
            else
                msg = sprintf('Elapsed Experiment Time: %i seconds',...
                              round(tElapsed));
            end
            disp(msg)
            lastPingTime = tElapsed;
        end

        if fileMode == 0
            pause(pauseBetweenAcquisitions_sec);
        elseif showPlayback == 1
            %Don't need as long of a pause for file processing, but need some
            %pause for the figure or else it doesn't open or update
            pause(0.000001);
        end

        for camIdx = 1:nCamsToUse
            outCentroids{camIdx}(counter,:)=[tElapsedCam{camIdx} reshape(centroidsTemp{camIdx}',1,...
                                                              size(wellCoordinates{camIdx},1)*2)];
            outCentroidsSizeTemp{camIdx}(counter,:) = [tElapsedCam{camIdx}, centroidsSizeTemp{camIdx} * ((wellToWellSpacing_mm/wellSpacingPix{camIdx})*(wellToWellSpacing_mm/wellSpacingPix{camIdx}))];
    
            if size(outDisplacements{camIdx},1)>1
                displacementsTemp{camIdx} = outCentroids{camIdx}(counter-1,2:end)-outCentroids{camIdx}(counter,2:end);
                displacementsTemp{camIdx} = reshape(displacementsTemp{camIdx},2,[]);
                displacementsTemp{camIdx} = sqrt(nansum(displacementsTemp{camIdx}.^2))*(wellToWellSpacing_mm/wellSpacingPix{camIdx});
                outDisplacements{camIdx}(counter,:) = [tElapsedCam{camIdx}, nansum([displacementsTemp{camIdx};outDisplacements{camIdx}(counter-1,2:end)])];
            else
                displacementsTemp{camIdx} = outCentroids{camIdx}(counter,2:end)-outCentroids{camIdx}(counter,2:end);
                displacementsTemp{camIdx} = reshape(displacementsTemp{camIdx},2,[]);
                displacementsTemp{camIdx} = sqrt(nansum(displacementsTemp{camIdx}.^2))*(wellToWellSpacing_mm/wellSpacingPix{camIdx});
                outDisplacements{camIdx}(counter,:) = [tElapsedCam{camIdx}, displacementsTemp{camIdx}];
            end
            
            if exist('prevCentroids','var')
                % Write out to file when the first time interval has passed
                %(must do a couple special things)
                if tc == 1 && tElapsed>writeToFileTiming

                    % average centroid position since last time data was
                    %written to file
                    avgCentroidPos = nanmean(outCentroids{camIdx}(1:counter,:));
                    avgCentroidPos(1) = outCentroids{camIdx}(counter,1);
                    dlmwrite(fullfile(pathName,...
                                      fileNameCentroidPosition{camIdx}),...
                             avgCentroidPos,'-append','delimiter',',',...
                             'precision',6);
                    dlmwrite(fullfile(pathName,...
                                      fileNameTotalDistTravel{camIdx}),...
                             outDisplacements{camIdx}(counter,:),'-append',...
                             'delimiter',',','precision',6);

                    % displacement since last time data was written to file
                    dispTravel = outDisplacements{camIdx}(counter,:)-outDisplacements{camIdx}(counter,:);
                    dispTravel(1) = outDisplacements{camIdx}(counter,1);
                    dlmwrite(fullfile(pathName,fileNameDispTravel{camIdx}),...
                             dispTravel,...
                             '-append','delimiter',',','precision',6);

                    % speed since last time data was written to file
                    instantSpeed = dispTravel./nan();
                    instantSpeed(1) = outDisplacements{camIdx}(counter,1);
                    dlmwrite(fullfile(pathName,fileNameInstantSpeed{camIdx}),...
                             instantSpeed,...
                             '-append','delimiter',',','precision',6);

                    % average centroid area since data was last written to file
                    avgCentroidSize = nanmean(outCentroidsSizeTemp{camIdx}(1:counter,:));
                    avgCentroidSize(1) = outDisplacements{camIdx}(counter,1);
                    dlmwrite(fullfile(pathName,...
                             fileNameCentroidSize{camIdx}),avgCentroidSize,...
                             '-append','delimiter',',','precision',6);

                % Write out to file at every time interval
                elseif tElapsed>tc*writeToFileTiming && tElapsed<(tc+1)*writeToFileTiming 
          
                    % average centroid position since data was last written
                    avgCentroidPos = nanmean(outCentroids{camIdx}(1:counter,:));
                    avgCentroidPos(1) = outCentroids{camIdx}(counter,1);
                    dlmwrite(fullfile(pathName,...
                                      fileNameCentroidPosition{camIdx}),...
                             avgCentroidPos,'-append','delimiter',',',...
                             'precision',6);
                    dlmwrite(fullfile(pathName,...
                                      fileNameTotalDistTravel{camIdx}),...
                             outDisplacements{camIdx}(counter,:),'-append',...
                             'delimiter',',','precision',6);

                    % displacement since last time data was written to file
                    dispTravel = outDisplacements{camIdx}(counter,:)-outDisplacements{camIdx}(1,:);
                    dispTravel(1) = outDisplacements{camIdx}(counter,1);
                    dlmwrite(fullfile(pathName,fileNameDispTravel{camIdx}),...
                             dispTravel,...
                             '-append','delimiter',',','precision',6);
    
                    % speed since last time data was written to file
                    instantSpeed = dispTravel./(outDisplacements{camIdx}(counter,1)-outDisplacements{camIdx}(1,1));
                    instantSpeed(1) = outDisplacements{camIdx}(counter,1);
                    dlmwrite(fullfile(pathName,...
                                      fileNameInstantSpeed{camIdx}),...
                             instantSpeed,'-append','delimiter',',',...
                             'precision',6);
    
                    % average centroid area since last time data was written
                    avgCentroidSize = nanmean(outCentroidsSizeTemp{camIdx}(1:counter,:));
                    avgCentroidSize(1) = outDisplacements{camIdx}(counter,1);
                    dlmwrite(fullfile(pathName,...
                                      fileNameCentroidSize{camIdx}),...
                             avgCentroidSize,...
                             '-append','delimiter',',','precision',6);
    
                end

            end

            prevCentroids{camIdx}=centroidsTemp{camIdx};
        end

        % Update the counter and the tc for all the cams - copied from above so
        % the same thing would be done for each cam's image
        if exist('prevCentroids','var')
            % decide if these coordinates should be written to file or not
            if ((tc == 1 && tElapsed>writeToFileTiming) || (tElapsed>tc*writeToFileTiming && tElapsed<(tc+1)*writeToFileTiming))

                %Restarting these variables at position 1 - every prior row is
                %no longer needed.
                outCentroids{camIdx}(1,:) = outCentroids{camIdx}(counter,:);
                outCentroidsSizeTemp{camIdx}(1,:) = outCentroidsSizeTemp{camIdx}(counter,:);
                outDisplacements{camIdx}(1,:) = outDisplacements{camIdx}(counter,:);

                counter = 1;
                tc=tc+1;
            end
        end
    end
    
    if mod(counter,100)==0
        cla;
    end

    counter=counter+1;
    if fileMode == 0
        notDone = tElapsed < experimentLength;
    end
end


%Stop the videos
if fileMode == 0
    for camIdx=1:nCamsToUse
        stop(vids{camIdx});
        if makeBackupVideo == 1
            try
                close(diskLoggers{camIdx});
                fclose(fidT{camIdx});
            end
        end
    end
end
%Close the plot
close(gcf);
%% Close the file handles
for camIdx=1:nCamsToUse
    fclose(fidA{camIdx});
    fclose(fidB{camIdx});
    fclose(fidC{camIdx});
    fclose(fidD{camIdx});
    fclose(fidE{camIdx});
    if fileMode == 0
        fclose(fidT{camIdx});
    end
end
fclose(fidG);
disp(['Done. Total Elapsed Experiment Time: ' num2str(tElapsed)]);


% fires when main function terminates or when ctrl-c is typed
function cleanUpVids(vids,vhs,fidTs,nCamsToUse)
    fprintf('Stopping video acquisition...\n');
    for cam=1:nCamsToUse
        if(isvalid(vids{cam}))
            stop(vids{cam});
        end
        try
            close(vhs{cam});
            fclose(fidTs{cam});
        end
    end
    fprintf('Stopped\n');
end


end

