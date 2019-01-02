
function [big_obj,aperture,fourier_error,initial_obj,initial_aperture] = ePIE_probe_strip(ePIE_inputs,varargin)
%varargin = {beta_obj, beta_ap}
optional_args = {0.9 0.9}; %default values for varargin parameters
rng('shuffle','twister');
%% setup working and save directories

dir = pwd;
save_string = [ dir '/Results_ptychography/']; % Place to save results
imout = 1; % boolean to determine whether to monitor progress or not
[~,jobID] = system('echo $JOB_ID');
jobID = jobID(~isspace(jobID));
if isempty(jobID)
    jobID = 'local';
end
%% Load inputs from struct
diffpats = ePIE_inputs(1).Patterns;
positions = ePIE_inputs(1).Positions;
pixel_size = ePIE_inputs(1).PixelSize;
big_obj = ePIE_inputs(1).InitialObj;
aperture_radius = ePIE_inputs(1).ApRadius;
aperture = ePIE_inputs(1).InitialAp;
iterations = ePIE_inputs(1).Iterations;
saveOutput = ePIE_inputs.saveOutput;
filename = ePIE_inputs(1).FileName;
strip_direction = ePIE_inputs(1).strip_direction; %'R' for row-wise strips, 'C' for column-wise
filename = strcat('reconstruction_ePIE_probe_strip_',filename,'_',jobID);
filename = strrep(filename,'__','_');
%% parameter inputs
if isfield(ePIE_inputs, 'updateAp')
    update_aperture = ePIE_inputs.updateAp;
else
    update_aperture = 1;
end

if isfield(ePIE_inputs, 'GpuFlag')
    gpu = ePIE_inputs(1).GpuFlag;
else
    gpu = 0;
end

if isfield(ePIE_inputs, 'miscNotes')
    miscNotes = ePIE_inputs.miscNotes;
else
    miscNotes = 'None';
end

if isfield(ePIE_inputs, 'showim')
    showim = ePIE_inputs(1).showim;
else
    showim = 0;
end

if isfield(ePIE_inputs, 'do_posi');
    do_posi = ePIE_inputs.do_posi;
else
    do_posi = 0;
end
if isfield(ePIE_inputs, 'save_intermediate');
    save_intermediate = ePIE_inputs.save_intermediate;
else
    save_intermediate = 0;
end
if isfield(ePIE_inputs, 'probe_mask_flag');
    probe_mask_flag = ePIE_inputs.probe_mask_flag;
else
    probe_mask_flag = 0;
end
if isfield(ePIE_inputs, 'obj_scale');
    obj_scale = ePIE_inputs.obj_scale;
else
    obj_scale = 1;
end
if isfield(ePIE_inputs, 'update_stripwise');
    update_stripwise = ePIE_inputs.update_stripwise;
else
    update_stripwise = 1;
end
if isfield(ePIE_inputs, 'strip_width');
    strip_width = ePIE_inputs.strip_width;
else
    strip_width = 3;
end
if strcmp(strip_direction, 'R') %for tilt-axis = x
    strip_squeeze = 4;
elseif strcmp(strip_direction, 'C') %for tilt-axis = y
    strip_squeeze = 3;
else
    error('strip_direction must be either ''R'' or ''C''');
end
kernel = make_gauss(strip_width,strip_width);
clear ePIE_inputs

%% === Reconstruction parameters frequently changed === %%
nva = length(varargin);
optional_args(1:nva) = varargin;
[beta_obj, beta_ap] = optional_args{:};
freeze_aperture = Inf;
%% print parameters
fprintf('filename = %s\n', filename);
fprintf('iterations = %d\n', iterations);
fprintf('beta probe = %0.5f\n', beta_ap);
fprintf('beta obj = %0.5f\n', beta_obj);
fprintf('gpu flag = %d\n', gpu);
fprintf('initial probe radius = %f\n', aperture_radius);
fprintf('updating probe = %d\n', update_aperture);
fprintf('positivity = %d\n', do_posi);
fprintf('probe mask = %d\n', probe_mask_flag);
fprintf('obj_scale = %f\n', obj_scale);
fprintf('strip_direction = %s\n', strip_direction);
fprintf('strip_width = %d\n', strip_width);
fprintf('misc notes: %s\n', miscNotes);
%% Define parameters from data and for reconstruction
for ii = 1:size(diffpats,3)
    diffpats(:,:,ii) = fftshift(sqrt(diffpats(:,:,ii)));
end
diffpats = single(diffpats);
[y_kspace,~] = size(diffpats(:,:,1)); % Size of diffraction patterns
nApert = size(diffpats,3);

little_area = y_kspace; % Region of reconstruction for placing back into full size image

%% Get centre positions for cropping (should be a 2 by n vector)
%positions = convert_to_pixel_positions(positions,pixel_size);
[pixelPositions, bigx, bigy] = ...
    convert_to_pixel_positions_testing5(positions,pixel_size,little_area);
centrey = round(pixelPositions(:,2));
centrex = round(pixelPositions(:,1));
centBig = round((bigx+1)/2);
Y1 = centrey - floor(y_kspace/2); Y2 = Y1+y_kspace-1;
X1 = centrex - floor(y_kspace/2); X2 = X1+y_kspace-1;
%% build strip index array 
[~, iy] = findpeaks(double(centrey)); 
n_strip_R = iy(1); %number of horizontal strips
n_strip_C = (nApert/iy(1)); % number of vertical strips

%% create initial aperture?and object guesses
if aperture == 0
    aperture = single(((makeCircleMask(round(aperture_radius./pixel_size),little_area))));
    initial_aperture = aperture;
else
    aperture = single(aperture);
    initial_aperture = aperture;
end

if update_stripwise == 1
    all_aps = repmat(aperture, [1 1 n_strip_R n_strip_C]);
    new_aps = repmat(aperture, [1 1 n_strip_R n_strip_C]);
end

if probe_mask_flag
    probe_mask = single(((makeCircleMask(1.20*round(aperture_radius./pixel_size),little_area)))); %loose support
    probe_mask(probe_mask == 0) = 1e-8; %prevent NaN
end

if big_obj == 0
%     big_obj = single(1e-3.*rand(bigx,bigy)).*exp(1i*(1e-3.*rand(bigx,bigy)));
    big_obj = single(obj_scale.*ones(bigx,bigy));
    initial_obj = big_obj;
else
    big_obj = single(big_obj);
    initial_obj = big_obj;
end

fourier_error = zeros(iterations,nApert);

if gpu == 1
    display('========ePIE reconstructing with GPU========')
    diffpats = gpuArray(diffpats);
    fourier_error = gpuArray(fourier_error);
    big_obj = gpuArray(big_obj);
    if update_stripwise == 1
        all_aps = gpuArray(all_aps);
        new_aps = gpuArray(new_aps);
    else
        aperture = gpuArray(aperture);
    end
else
    display('========ePIE reconstructing with CPU========')
end

best_err = 100; % check to make sure saving reconstruction with best error

%% Main ePIE itteration loop
disp('========beginning reconstruction w/ probe strip averaging=======');
for itt = 1:iterations
    tic;
    for aper = randperm(nApert)
%         bigObjShifted = circshift(big_obj, [-1*(centrey(aper) - centBig) -1*(centrex(aper) - centBig)]);
%         rspace = croppedOut(bigObjShifted,y_kspace);        
        rspace = big_obj(Y1(aper):Y2(aper), X1(aper):X2(aper));
        if update_stripwise == 1
            [ir, ic] = ind2sub([n_strip_R n_strip_C], aper);
            aperture = squeeze(all_aps(:,:,ir,ic)); 
        end
        buffer_rspace = rspace;
        object_max = max(abs(rspace(:))).^2;
        probe_max = max(abs(aperture(:))).^2;

%% Create new exitwave
        buffer_exit_wave = rspace.*(aperture);
        update_exit_wave = buffer_exit_wave;
        temp_dp = fft2(update_exit_wave);
        check_dp = abs(temp_dp);
        current_dp = diffpats(:,:,aper);
        missing_data = current_dp == -1;
        k_fill = temp_dp(missing_data);
        temp_dp = current_dp.*exp(1i*angle(temp_dp)); % Replace reconstructed magnitudes with measured magnitudes
        temp_dp(missing_data) = k_fill;

%% Update the object

        temp_rspace = ifft2(temp_dp);
        new_exit_wave = temp_rspace;
        diff_exit_wave = new_exit_wave-buffer_exit_wave;
        update_factor_ob = beta_obj/probe_max;
        new_rspace = buffer_rspace + update_factor_ob.*conj(aperture).*(diff_exit_wave);
        if do_posi == 1
            new_rspace = max(0, real(new_rspace));
        end
        big_obj(Y1(aper):Y2(aper), X1(aper):X2(aper)) = new_rspace;
%% Update the probe

        if update_aperture == 1
%             if itt > iterations - freeze_aperture
%                 new_beta_ap = beta_ap*sqrt((iterations-itt)/iterations);
%                 update_factor_pr = new_beta_ap./object_max;
%              else
%                 update_factor_pr = beta_ap./object_max;
%             end
            update_factor_pr = beta_ap ./ object_max;
            aperture = aperture +update_factor_pr*conj(buffer_rspace).*(diff_exit_wave);
            if probe_mask_flag
                aperture = aperture .* probe_mask;
            end
            if update_stripwise == 1
                all_aps(:,:,ir,ic) = aperture; %put updated aperture into master array
            end
        end 

        fourier_error(itt,aper) = sum(sum(abs(current_dp(missing_data ~= 1) - check_dp(missing_data ~= 1))))./sum(sum(current_dp(missing_data ~= 1)));

    end
    if  mod(itt,showim) == 0 && imout == 1;

        figure(3)

        hsv_big_obj = make_hsv(big_obj,1);
        hsv_aper = make_hsv(aperture,1);
        subplot(2,2,1)
        imagesc(abs(big_obj)); axis image; colormap gray; title(['reconstruction pixel size = ' num2str(pixel_size)] )
        subplot(2,2,2)
        imagesc(hsv_aper); axis image; colormap gray; title('aperture single'); colorbar
        subplot(2,2,3)
        errors = sum(fourier_error,2)/nApert;
        fprintf('%d. Error = %f, scale = %f\n',itt,errors(itt),max(max(abs(aperture))));
        plot(errors); ylim([0,0.2]);
        subplot(2,2,4)
        imagesc(log(fftshift(check_dp))); axis image
        drawnow 
        %         drawnow
        %         writeVideo(writerObj,getframe(h)); % take screen shot
    end

    mean_err = sum(fourier_error(itt,:),2)/nApert;
    
    if best_err > mean_err
        best_obj = big_obj;
        best_err = mean_err;
    end

    if update_stripwise == 1
        
        switch strip_direction
            case 'R'
                %averaging probes along horizontal strips of width (2*strip_width+1)
                for pos = 1:n_strip_R
                    if pos > strip_width && pos < (n_strip_R - strip_width)
                        temp_aps = mean(all_aps(:,:,pos-strip_width:pos+strip_width,:),strip_squeeze);
                        %normalized gaussian weighting
                        for iii = 1:(2*strip_width + 1)
                            temp_aps(:,:,iii) = temp_aps(:,:,iii) .* kernel(iii);
                        end
                        new_aps(:,:,pos-strip_width:pos+strip_width,:) = repmat(sum(temp_aps,3),[1 1 2*strip_width+1 n_strip_C]);
                    end
                end
                
            case 'C'
                %averaging probes along vertical strips of width (2*strip_width+1)
                for pos = 1:n_strip_C
                    if pos > strip_width && pos < (n_strip_C - strip_width)
                        temp_aps = squeeze(mean(all_aps(:,:,:,pos-strip_width:pos+strip_width),strip_squeeze));
                        %normalized gaussian weighting
                        for iii = 1:(2*strip_width + 1)
                            temp_aps(:,:,iii) = temp_aps(:,:,iii) .* kernel(iii);
                        end
                        new_aps(:,:,:,pos-strip_width:pos+strip_width) = repmat(sum(temp_aps,3),[1 1 n_strip_R 2*strip_width+1]);
                    end
                end
        end
        
    end

    all_aps = new_aps;

    if save_intermediate == 1 && mod(itt,round(iterations/10)) == 0 && itt < iterations
        big_obj_g = gather(big_obj);
        all_aps_g = gather(all_aps);
        all_aps_g = squeeze(mean(all_aps_g(:,:,:,:),strip_squeeze));
        save([save_string filename '_itt' num2str(itt) '.mat'],...
            'big_obj_g','all_aps_g','-v7.3');
    end

t1 = toc; 
fprintf('%d. Error = %f\n time elapsed %f s\n',itt,mean_err, t1);
fprintf('\n');
end


disp('======reconstruction finished=======')
drawnow

fourier_error = gather(fourier_error);
best_obj = gather(best_obj);
all_aps = gather(all_aps);

all_aps = squeeze(mean(all_aps(:,:,:,:),strip_squeeze));

if saveOutput == 1
    save([save_string 'best_obj_' filename '.mat'],'best_obj','all_aps','initial_obj','initial_aperture','fourier_error');
end

%% Function for converting positions from experimental geometry to pixel geometry

%     function [positions] = convert_to_pixel_positions(positions,pixel_size)
%         positions = positions./pixel_size;
%         positions(:,1) = (positions(:,1)-min(positions(:,1)));
%         positions(:,2) = (positions(:,2)-min(positions(:,2)));
%         positions(:,1) = (positions(:,1)-round(max(positions(:,1))/2));
%         positions(:,2) = (positions(:,2)-round(max(positions(:,2))/2));
%         positions = round(positions);
%         bigx =little_area + max(positions(:))*2+10; % Field of view for full object
%         bigy = little_area + max(positions(:))*2+10;
%         big_cent = floor(bigx/2)+1;
%         positions = positions+big_cent;
%         
%         
%     end
function [shiftDistancesX, shiftDistancesY, truePositions, positions, bigx, bigy] = ...
    convert_to_pixel_positions_testing3(positions,pixel_size,little_area)

        
        positions = positions./pixel_size;
        positions(:,1) = (positions(:,1)-min(positions(:,1)));
        positions(:,2) = (positions(:,2)-min(positions(:,2)));
        truePositions(:,1) = (positions(:,1) - max(positions(:,1))/2);
        truePositions(:,2) = (positions(:,2) - max(positions(:,2))/2);
        positions(:,1) = (positions(:,1)-round(max(positions(:,1))/2));
        positions(:,2) = (positions(:,2)-round(max(positions(:,2))/2));
        
        positions = round(positions);
        bigx =little_area + max(positions(:))*2+10; % Field of view for full object
        bigy = little_area + max(positions(:))*2+10;
%         bigx = little_area;
%         bigy = little_area;
        big_cent = floor(bigx/2)+1;
        positions = positions+big_cent;
        truePositions = truePositions + big_cent;
        
        shiftDistancesX = truePositions(:,1) - positions(:,1);
        shiftDistancesY = truePositions(:,2) - positions(:,2);
        
        
        
end

function [shiftDistancesX, shiftDistancesY, truePositions, positions, bigx, bigy] = ...
    convert_to_pixel_positions_testing4(positions,pixel_size,little_area)

        
        positions = positions./pixel_size;
        positions(:,1) = (positions(:,1)-min(positions(:,1)));
        positions(:,2) = (positions(:,2)-min(positions(:,2)));
        truePositions(:,1) = (positions(:,1) - round(max(positions(:,1))/2));
        truePositions(:,2) = (positions(:,2) - round(max(positions(:,2))/2));
        
        positions = round(truePositions);
        bigx =little_area + max(positions(:))*2+10; % Field of view for full object
        bigy = little_area + max(positions(:))*2+10;
%         bigx = little_area;
%         bigy = little_area;
        big_cent = floor(bigx/2)+1;
        positions = positions+big_cent;
        truePositions = truePositions + big_cent;
        
        shiftDistancesX = truePositions(:,1) - positions(:,1);
        shiftDistancesY = truePositions(:,2) - positions(:,2);
        
        
        
end

function [pixelPositions, bigx, bigy] = ...
    convert_to_pixel_positions_testing5(positions,pixel_size,little_area)

        
        pixelPositions = positions./pixel_size;
        pixelPositions(:,1) = (pixelPositions(:,1)-min(pixelPositions(:,1))); %x goes from 0 to max
        pixelPositions(:,2) = (pixelPositions(:,2)-min(pixelPositions(:,2))); %y goes from 0 to max
        pixelPositions(:,1) = (pixelPositions(:,1) - round(max(pixelPositions(:,1))/2)); %x is centrosymmetric around 0
        pixelPositions(:,2) = (pixelPositions(:,2) - round(max(pixelPositions(:,2))/2)); %y is centrosymmetric around 0
        
        bigx = little_area + round(max(pixelPositions(:)))*2+10; % Field of view for full object
        bigy = little_area + round(max(pixelPositions(:)))*2+10;

        big_cent = floor(bigx/2)+1;
        
        pixelPositions = pixelPositions + big_cent;
        
        
    end

%% 2D gaussian smoothing of an image

    function [smoothImg,cutoffRad]= smooth2d(img,resolutionCutoff)
        
        Rsize = size(img,1);
        Csize = size(img,2);
        Rcenter = round((Rsize+1)/2);
        Ccenter = round((Csize+1)/2);
        a=1:1:Rsize;
        b=1:1:Csize;
        [bb,aa]=meshgrid(b,a);
        sigma=(Rsize*resolutionCutoff)/(2*sqrt(2));
        kfilter=exp( -( ( ((sqrt((aa-Rcenter).^2+(bb-Ccenter).^2)).^2) ) ./ (2* sigma.^2) ));
        kfilter=kfilter/max(max(kfilter));
        kbinned = my_fft(img);
        
        kbinned = kbinned.*kfilter;
        smoothImg = my_ifft(kbinned);
        
        [Y, X] = ind2sub(size(img),find(kfilter<(exp(-1))));
        
        Y = Y-(size(img,2)/2);
        X = X-(size(img,2)/2);
        R = sqrt(Y.^2+X.^2);
        cutoffRad = ceil(min(abs(R)));
    end

%% Fresnel propogation
    function U = fresnel_advance (U0, dx, dy, z, lambda)
        % The function receives a field U0 at wavelength lambda
        % and returns the field U after distance z, using the Fresnel
        % approximation. dx, dy, are spatial resolution.
        
        k=2*pi/lambda;
        [ny, nx] = size(U0);
        
        Lx = dx * nx;
        Ly = dy * ny;
        
        dfx = 1./Lx;
        dfy = 1./Ly;
        
        u = ones(nx,1)*((1:nx)-nx/2)*dfx;
        v = ((1:ny)-ny/2)'*ones(1,ny)*dfy;
        
        O = my_fft(U0);
        
        H = exp(1i*k*z).*exp(-1i*pi*lambda*z*(u.^2+v.^2));
        
        U = my_ifft(O.*H);
    end

%% Make a circle of defined radius

    function out = makeCircleMask(radius,imgSize)
        
        
        nc = imgSize/2+1;
        n2 = nc-1;
        [xx, yy] = meshgrid(-n2:n2-1,-n2:n2-1);
        R = sqrt(xx.^2 + yy.^2);
        out = R<=radius;
    end

%% Function for creating HSV display objects for showing phase and magnitude
%  of a reconstruction simaultaneously

    function [hsv_obj] = make_hsv(initial_obj, factor)
        
        [sizey,sizex] = size(initial_obj);
        hue = angle(initial_obj);
        
        value = abs(initial_obj);
        hue = hue - min(hue(:));
        hue = (hue./max(hue(:)));
        value = (value./max(value(:))).*factor;
        hsv_obj(:,:,1) = hue;
        hsv_obj(:,:,3) = value;
        hsv_obj(:,:,2) = ones(sizey,sizex);
        hsv_obj = hsv2rgb(hsv_obj);
    end
%% Function for defining a specific region of an image

    function [roi] = get_roi(image, centrex,centrey,crop_size)
        
        bigy = size(image,1);
        bigx = size(image,2);
        
        half_crop_size = floor(crop_size/2);
        if mod(crop_size,2) == 0
            roi = {centrex - half_crop_size:centrex + (half_crop_size - 1);...
                centrey - half_crop_size:centrey + (half_crop_size - 1)};
            
        else
            roi = {centrex - half_crop_size:centrex + (half_crop_size);...
                centrey - half_crop_size:centrey + (half_crop_size)};
            
        end
    end

%% Fast Fourier transform function
    function kout = my_fft(img)
        kout = fftshift(fftn((ifftshift(img))));
    end
%% Inverse Fast Fourier transform function
    function realout = my_ifft(k)
        realout =fftshift((ifftn(ifftshift(k))));
        %realout =ifftshift((ifftn(fftshift(k))));
        
    end
%% make_gauss creates a L1-normalized gaussian of size 2n+1 with defined sigma
    function [ Gauss ] = make_gauss( n,sigma )
        width = -n:1:n;
        G = exp(-width.^2/(sigma)^2);
        Gauss = G ./ norm(G,1);
    end
end



