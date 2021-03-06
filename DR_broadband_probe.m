%% Streamlined ePIE code for reconstructing from experimental diffraction patterns
function [big_obj,aperture,fourier_error,initial_obj,initial_aperture] = DR_broadband_probe(ePIE_inputs,varargin)
%varargin = {beta_ap, beta_obj, modeSuppression}
optional_args = {0.8,0.5,0.7, 0,0}; %default values for optional parameters
nva = length(varargin);
optional_args(1:nva) = varargin;
[beta_obj,beta_ap,alpha, modeSuppression,probe_norm ] = optional_args{:};
rng('shuffle','twister');
%% setup working and save directories

dir = pwd;
save_string = [ dir '/Results_ptychography/']; % Place to save results


%% essential inputs
diffpats = ePIE_inputs(1).Patterns;
positions = ePIE_inputs(1).Positions;
filename = ePIE_inputs(1).FileName;
pixel_size = ePIE_inputs(1).PixelSize;
big_obj = ePIE_inputs(1).InitialObj;
aperture_radius = ePIE_inputs(1).ApRadius;
aperture = ePIE_inputs(1).InitialAp;
iterations = ePIE_inputs(1).Iterations;
lambda = ePIE_inputs(1).lambda;
S = ePIE_inputs(1).S;
[~,job_ID] = system('echo $JOB_ID');
job_ID = job_ID(~isspace(job_ID));
nModes = length(pixel_size);
central_mode = ePIE_inputs.central_mode; %best mode for probe replacement
fresnel_dist = ePIE_inputs.fresnel_dist; %probe to sample
filename = strcat('reconstruction_DR_probe_',filename,'_',job_ID);
filename = strrep(filename,'__','_');
%% parameter inputs
if isfield(ePIE_inputs, 'saveOutput')
    saveOutput = ePIE_inputs(1).saveOutput;
else
    saveOutput = 1;
end
if isfield(ePIE_inputs, 'saveIntermediate')
    saveIntermediate = ePIE_inputs(1).saveIntermediate;
else
    saveIntermediate = 0;
end
if isfield(ePIE_inputs, 'GpuFlag')
    gpu = ePIE_inputs(1).GpuFlag;
else
    gpu = 0;
end
if isfield(ePIE_inputs, 'apComplexGuess')
    apComplexGuess = ePIE_inputs(1).apComplexGuess;
else
    apComplexGuess = 0;
end
if isfield(ePIE_inputs, 'probeMaskFlag')
    probeMaskFlag = ePIE_inputs(1).probeMaskFlag;
else probeMaskFlag = 0;
end

if isfield(ePIE_inputs, 'supportMaskFlag')
    supportMaskFlag = ePIE_inputs(1).supportMaskFlag;
else supportMaskFlag = 0;
end

if isfield(ePIE_inputs, 'averagingConstraint')
    averagingConstraint = ePIE_inputs(1).averagingConstraint;
else
    averagingConstraint = 0;
end
if isfield(ePIE_inputs, 'Posi')
    strongPosi = ePIE_inputs(1).Posi;
else
    strongPosi = 0;
end
if isfield(ePIE_inputs, 'Realness')
    realness = ePIE_inputs(1).Realness;
else
    realness = 0;
end
if isfield(ePIE_inputs, 'updateAp')
    updateAp = ePIE_inputs.updateAp;
else
    updateAp = 1;
end
if isfield(ePIE_inputs, 'miscNotes')
    miscNotes = ePIE_inputs.miscNotes;
else
    miscNotes = 'None';
end
%% === Reconstruction parameters frequently changed === %%
beta_pos = 0.9; % Beta for enforcing positivity
do_posi = 0;
update_aperture_itt = 0;
%%
fprintf('dataset = %s\n',ePIE_inputs.FileName);
fprintf('output filename = %s\n', filename);
fprintf('iterations = %d\n',iterations);
fprintf('beta object = %0.1f\n',beta_obj);
fprintf('beta probe = %0.1f\n',beta_ap);
fprintf('number of modes = %d\n',nModes);
fprintf('gpu flag = %d\n',gpu);
fprintf('averaging objects = %d\n',averagingConstraint);
fprintf('complex probe guess = %d\n',apComplexGuess);
fprintf('probe mask flag = %d\n',probeMaskFlag);
fprintf('support mask flag = %d\n',supportMaskFlag);
fprintf('strong positivity = %d\n',strongPosi);
fprintf('realness enforced = %d\n',realness);
fprintf('updating probe = %d\n',updateAp);
fprintf('enforcing positivity = %d\n',do_posi);
fprintf('updating probe after iteration %d\n',update_aperture_itt);
fprintf('mode suppression = %d\n',modeSuppression);
fprintf('misc notes: %s\n', miscNotes);
clear ePIE_inputs
%% Define parameters from data and for reconstruction
for ii = 1:size(diffpats,3)     %diffpats are intensities in fact
    diffpats(:,:,ii) = single(fftshift(sqrt(diffpats(:,:,ii))));
end
goodInds = diffpats(:,:,1) ~= -1;
[N1,N2,nApert] = size(diffpats); % Size of diffraction patterns
best_err = 100; % check to make sure saving reconstruction with best error
little_cent = floor(N1/2) + 1;
cropVec = (1:N1) - little_cent;
mcm = @makeCircleMask;
for m = 1:length(lambda)
    %% Get centre positions for cropping (should be a 2 by n vector)
    [pixelPositions, bigx, bigy] = convert_to_pixel_positions_testing5(positions,pixel_size(m),N1);
    centrey = round(pixelPositions(:,2));
    centrex = round(pixelPositions(:,1));
    centBig = round((bigx+1)/2);
    Y1(:,m) = centrey - floor(N1/2); Y2(:,m) = Y1(:,m)+N1-1;
    X1(:,m) = centrex - floor(N1/2); X2(:,m) = X1(:,m)+N1-1;
    %{
    for aper = 1:nApert
        cropR(aper,:,m) = cropVec+centBig+(centrey(aper)-centBig);
        cropC(aper,:,m) = cropVec+centBig+(centrex(aper)-centBig);
    end
    %}
    %% create initial aperture?and object guesses
    if aperture{m} == 0
        if apComplexGuess == 1
            aperture{m} = single(((feval(mcm,(ceil(aperture_radius./pixel_size(m))),N1).*...
                rand(N1,N1) .* exp(1i*rand(N1,N1)))));
        else
            aperture{m} = single(feval(mcm,(ceil(aperture_radius./pixel_size(m))),N1));
        end
        
        initial_aperture{m} = aperture{m};
    else
        %         display('using supplied aperture')
        aperture{m} = single(aperture{m});
        initial_aperture{m} = aperture{m};
    end
    
    if probeMaskFlag == 1
        %         display('applying loose support')
        %     probeMask{m} = double(aperture{m} > 0);
        probeMask{m} = double(feval(mcm,(ceil(aperture_radius./pixel_size(m))),N1));
    else
        probeMask{m} = [];
    end
    
    if big_obj{m} == 0
        big_obj{m} = single(rand(bigx,bigy)).*exp(1i*(rand(bigx,bigy)));
        %big_obj{m} = single(0.5*ones(bigx,bigy));
        initial_obj{m} = big_obj{m};
    else
        big_obj{m} = single(big_obj{m});
        initial_obj{m} = big_obj{m};
    end
    
    if supportMaskFlag ==1
        %{
        radius = round(aperture_radius/pixel_size(m)*1.6);
        r = floor(bigx/2) - radius + (0:2*radius);
        support{m} = zeros(bigx,bigy);
        support{m}(r,r)=1;
        support{m} = ~support{m};
        %}
        %
        support{m} = zeros(bigx,bigy);
        mask_obj= aperture{m}~=0;
        for ii=1:nApert
            support{m}(Y1(ii,m):Y2(ii,m), X1(ii,m):X2(ii,m)) = support{m}(Y1(ii,m):Y2(ii,m), X1(ii,m):X2(ii,m)) | mask_obj;
        end
        support{m} = ~support{m};        
        %}
    end
    
    [XX,YY] = meshgrid(1:bigx,1:bigy);
    X_cen = floor(bigx/2); Y_cen = floor(bigy/2);
    R2 = (XX-X_cen).^2 + (YY-Y_cen).^2;
    Kfilter{m} = exp(-R2/(2*400)^2);Kfilter{m} = single(Kfilter{m}/max(Kfilter{m}(:)));    
end
clear XX YY R2

fourier_error = zeros(iterations,nApert);
nMode = length(lambda);
Z =cell(nMode);
for m=1:length(lambda)
    Z{m} = rand(N1,N2,nApert,'single');
end
%ws = w_init + (w_final-w_init)* ((1:iterations)/iterations).^order;
Alpha = alpha - (alpha-0.1)* ((1:iterations)/iterations).^2;
%z = cell(nMode,1);
cdp = class(diffpats);
u_old = cell(nMode,1);
z_F = cell(nMode);
z_O = cell(nMode,1);
%Pu = cell(nMode,1);
collected_mag = zeros([N1, N2],cdp);
sum_dp = zeros(nMode,1);

best_obj = cell(m);

%% probe replacement parameters
scaling_ratio = pixel_size ./ pixel_size(central_mode);
for mm = 1:length(lambda)
    scoop_size = round(N1/scaling_ratio(mm));
    scoop_center = round((scoop_size+1)/2);
    scoop_vec{mm} = (1:scoop_size) - scoop_center + little_cent;
    scoop_range(mm) = range(scoop_vec{mm})+1;
    if scoop_range(mm) > N1
        pad_pre(mm) = ceil((scoop_range(mm)-N1)/2);
        pad_post(mm) = floor((scoop_range(mm)-N1)/2);
    else
        pad_pre(mm) = 0;
        pad_post(mm) = 0;
    end
end
cutoff = floor(iterations/2);
prb_rplmnt_weight = min((cutoff^4/10)./(1:iterations).^4,0.1);
%% pre allocation of propagators
for mm = 1:length(lambda)
    k = 2*pi/lambda(mm);
    Lx = pixel_size(mm)*N1;
    Ly = pixel_size(mm)*N1;
    dfx = 1./Lx;
    dfy = 1./Ly;
    u = ones(N1,1)*((1:N1)-N1/2)*dfx;
    v = ((1:N1)-N1/2)'*ones(1,N1)*dfy;
    if mm ~= central_mode
        H_fwd{mm} = ifftshift(exp(1i*k*fresnel_dist).*exp(-1i*pi*lambda(mm)*fresnel_dist*(u.^2+v.^2)));
        %H_bk{mm} = ifftshift(exp(1i*k*-fresnel_dist).*exp(-1i*pi*lambda(mm)*-fresnel_dist*(u.^2+v.^2)));
    else
        %H_fwd{mm} =exp(1i*k*fresnel_dist).*exp(-1i*pi*lambda(mm)*fresnel_dist*(u.^2+v.^2));
        H_bk{mm} = exp(1i*k*-fresnel_dist).*exp(-1i*pi*lambda(mm)*-fresnel_dist*(u.^2+v.^2));
    end
end
probe_rpl = zeros(N1,cdp);
%% GPU
if gpu == 1
    display('========DR reconstructing with GPU========')
    diffpats = gpuArray(diffpats);
    fourier_error = gpuArray(fourier_error);
    big_obj = cellfun(@gpuArray, big_obj, 'UniformOutput', false);
    aperture = cellfun(@gpuArray, aperture, 'UniformOutput', false);
    S = gpuArray(S);
    collected_mag = gpuArray(collected_mag);
    sum_dp = gpuArray(sum_dp);
    Z = cellfun(@gpuArray, Z, 'UniformOutput', false);
    probe_rpl = gpuArray(probe_rpl);
else
    display('========DR reconstructing with CPU========')
end

%% Main ePIE itteration loop
disp('========beginning reconstruction=======');

for itt = 1:iterations
    tic
    %w = ws(itt);
    w=0.1;
    alpha = Alpha(itt);
    %alpha = 0.7;
    for aper = randperm(nApert)
        current_dp = diffpats(:,:,aper);
        collected_mag(:)=0;
        
        %% collect magnitudes
        for m = 1:length(lambda)
            u_old{m} = big_obj{m}(Y1(aper,m):Y2(aper,m), X1(aper,m):X2(aper,m));
            %u_old{m} = big_obj{m}(cropR(aper,:,m), cropC(aper,:,m));
            
            %weight = sqrt(S(m)) ./ ((sum(abs(aperture{m}(:)).^2)))^0.5;
            Pu{m} = u_old{m}.*aperture{m};
            z_O{m} = fft2(Pu{m});
            z_F{m} = (1+alpha).*z_O{m} - alpha.*Z{m}(:,:,aper);
            %z_F{m} = 2*z_O{m} - Z{m}(:,:,aper);
            %z_F{m} = 2*fft2(Pu) - Z{m}(:,:,aper);
            %z_F{m} = z_u{m};
            collected_mag = collected_mag + abs(z_F{m}).^2;
        end        
        collected_mag = sqrt(collected_mag);
        scale = (1-w).*current_dp./collected_mag + w;
        %scale = current_dp./collected_mag;
        fourier_error(itt,aper) = sum( abs(current_dp(goodInds)-collected_mag(goodInds)) )...
            ./ sum(current_dp(goodInds));
        
        %% update object & probe
        for m = 1:length(lambda)
            z_F{m}(goodInds) =  scale(goodInds).*z_F{m}(goodInds);
            z = z_F{m} + alpha.*( Z{m}(:,:,aper)-z_O{m});
            %z = 0.5*(z_F{m} +  Z{m}(:,:,aper));
            %z = 2*z_F{m} - z_O{m};
            %z = beta*( z_F{m} + Z{m}(:,:,aper) ) + (1-2*beta)*z_O{m};
            Z{m}(:,:,aper) = z;
            
            Pu_new = ifft2(z);
            diff = Pu_new- Pu{m};
 
            abs_ap = abs(aperture{m});
            probe_max = max(abs_ap(:));
            dt = beta_obj/probe_max^2;
            u_new = ( ((1-beta_obj)/dt).*u_old{m} + Pu_new.*conj(aperture{m}))./ ...
                ( (1-beta_obj)/dt +  abs_ap.^2);
            %u_new = u_old{m} + dt*conj(aperture{m}).*diff;
            
            if realness == 1,u_new = real(u_new); end
            if strongPosi == 1,u_new(u_new < 0) = 0;end            
            if do_posi == 1 && strongPosi == 0
                u_new(u_new < 0) = u_old{m}(u_new < 0) - beta_pos.*u_new(u_new < 0);
            end
                       
            big_obj{m}(Y1(aper,m):Y2(aper,m), X1(aper,m):X2(aper,m)) = u_new;
            %big_obj{m}(cropR(aper,:,m), cropC(aper,:,m)) = u_new;
            if supportMaskFlag && itt==5, big_obj{m}(support{m})=0; end
            %if itt==10, FU = fftshift(fft2(big_obj{m})).*Kfilter{m}; big_obj{m} = ifft2(ifftshift(FU)); end
            
            % Update the probe          
            if itt > update_aperture_itt && updateAp == 1
                if modeSuppression==0 || mod(m,3)~=0
                    abs_u = abs(u_new);
                    object_max = max(abs_u(:));
                    ds = beta_ap ./ object_max^2;
                    aperture{m} = aperture{m} +ds*conj(u_old{m}).*(diff);
                    %aperture{m} = ((1-beta_ap)*aperture{m} + ds*Pu_new.*conj(u_old{m})) ./ ( (1-beta_ap) + ds*abs(u_old{m}).^2 );
                    %aperture{m} = ((1-beta_ap).*aperture{m} + ds.*Pu_new.*conj(u_new)) ./ ( (1-beta_ap) + ds.*abs_u.^2 );
                    
                    if rand<0.1 
                        if scoop_range(m) > N1 %higher energy than central mode
                            Fcentral_probe = my_fft(aperture{central_mode}).*H_bk{central_mode};
                            Fprobe_replaced = padarray(Fcentral_probe,  [pad_pre(m) pad_pre(m)],'pre');
                            Fprobe_replaced = padarray(Fprobe_replaced, [pad_post(m) pad_post(m)],'post');
                            probe_rpl = my_ifft(Fprobe_replaced);
                            probe_rpl = probe_rpl(pad_pre(m)+1:end-pad_post(m),pad_pre(m)+1:end-pad_post(m));
                            %                     probe_rpl = my_ifft(my_fft(probe_rpl).*H_fwd{m});
                            probe_rpl = ifftn((fftn(probe_rpl).*H_fwd{m}));
                            %probe_rpl = ifftn(Fcentral_probe.*H_fwd{m});
                        elseif scoop_range(m) < N1 %lower energy than central mode
                            Fcentral_probe = my_fft(aperture{central_mode}).*H_bk{central_mode};
                            Fcentral_probe_cropped = Fcentral_probe(scoop_vec{m}, scoop_vec{m});
                            %match class of other arrays
                            probe_rpl(:)=0;
                            probe_rpl(scoop_vec{m},scoop_vec{m}) = my_ifft(Fcentral_probe_cropped);
                            %                     probe_rpl = my_ifft(my_fft(probe_rpl).*H_fwd{m});
                            probe_rpl = ifftn(fftn(probe_rpl).*H_fwd{m});
                            %probe_rpl = ifftn(Fcentral_probe.*H_fwd{m});
                        else
                            probe_rpl = aperture{m};
                        end
                        ap_updated = aperture{m} + prb_rplmnt_weight(itt)*(probe_rpl-aperture{m});
                        aperture{m} = norm(aperture{m},'fro')/norm(ap_updated,'fro')...
                            .*ap_updated;
                        %aperture{m} = ap_updated;
                    end
                    
                end
                if probeMaskFlag==1, aperture{m}=aperture{m}.*probeMask{m}; end
                if probe_norm, aperture{m} = aperture{m}./max(abs(aperture{m}(:)));  end
            end
            
            % update the weights
            S(m) = sum(abs(aperture{m}(:)).^2);
        end
    end 

    %% show images
    if mod(itt,10)==0
    for m=1:nMode
        [dim1,~] = size(big_obj{m});
        r = floor(dim1/2)+ (-100:100); c = floor(N1/2)+ (-100:100);
        figure(m); 
        subplot(1,2,1); imagesc(abs(big_obj{m})); colormap jet; axis image; set(gca,'YTick',[],'XTick',[]); colorbar
        subplot(1,2,2); imagesc(abs(aperture{m}(c,c))); colormap jet; axis image; set(gca,'YTick',[],'XTick',[]); colorbar
        drawnow;
    end
    end
    %}
    
    %% averaging between wavelengths
    if averagingConstraint == 1
        %         if gpu == 1
        averaged_obj = zeros([size(big_obj{1}) length(lambda)], cdp);
        interpMethod = 'linear';
        %         else
        %             averaged_obj = zeros([size(big_obj{1}) length(lambda)]);
        %             interpMethod = 'linear';
        %         end
        
        first_obj = big_obj{1};
        averaged_obj(:,:,1) = first_obj;
        ndim = floor(size(big_obj{1},1)/2);
        [xm, ym] = meshgrid(-ndim:ndim, -ndim:ndim);
        %k_arr = zeros(1,length(lambda));
        %k_arr(1) = 1;
        %rescaling all the objects to have the same pixel size as first obj
        %         parfor m = 2:length(lambda)
        for m = 2:length(lambda)
            xm_rescaled = xm .* (pixel_size(m) / pixel_size(1));
            ym_rescaled = ym .* (pixel_size(m) / pixel_size(1));
            ctrPixel = ceil((size(big_obj{m},1)+1) / 2);
            cropROI = big_obj{m}(ctrPixel-ndim:ctrPixel+ndim, ctrPixel-ndim:ctrPixel+ndim);
            resized_obj = interp2(xm_rescaled, ym_rescaled, cropROI, xm, ym, interpMethod, 0);
            resized_obj(resized_obj < 0) = 0;
            %no normalization for now
            %k_arr(m) = normalizer(first_obj, resized_obj);
            averaged_obj(:,:,m) = resized_obj;
        end
        averaged_obj = sum(averaged_obj,3) ./ length(lambda);
        %distribute back to big_objs
        big_obj{1} = averaged_obj;
        %         parfor m = 2:length(lambda)
        for m = 2:length(lambda)
            xm_rescaled = xm .* (pixel_size(1) / pixel_size(m));
            ym_rescaled = ym .* (pixel_size(1) / pixel_size(m));
            resized_obj = interp2(xm_rescaled, ym_rescaled, averaged_obj, xm, ym, interpMethod, 0);
            resized_obj(resized_obj < 0) = 0;
            ctrPixel = ceil((size(big_obj{m},1)+1) / 2);
            big_obj{m}(ctrPixel-ndim:ctrPixel+ndim, ctrPixel-ndim:ctrPixel+ndim) = resized_obj;           
        end
    end
       
    fourier_error(itt,isinf(fourier_error(itt,:))) = 0;
    mean_err = sum(fourier_error(itt,:),2)/nApert;
    
    if best_err > mean_err
        for m = 1:length(lambda)
            best_obj{m} = big_obj{m};
        end
        best_err = mean_err;
    end
    if saveOutput == 1
        if itt == 50 && saveIntermediate == 1
            if gpu == 1
                best_obj = cellfun(@gather, best_obj, 'UniformOutput', false);
            end
            save([filename '_iter_' num2str(itt) '.mat'], 'best_obj', '-v7.3');
            best_obj = cellfun(@gpuArray, best_obj, 'UniformOutput', false);
        end
    end
    toc
    fprintf('%d. Error = %f\n',itt,mean_err);
end
disp('======reconstruction finished=======')


if gpu == 1
    fourier_error = gather(fourier_error);
    best_obj = cellfun(@gather, best_obj, 'UniformOutput', false);
    aperture = cellfun(@gather, aperture, 'UniformOutput', false);
    big_obj = cellfun(@gather, big_obj, 'UniformOutput', false);
    initial_aperture = cellfun(@gather, initial_aperture, 'UniformOutput', false);
    % S = cellfun(@gather, S, 'UniformOutput', false);
    S = gather(S);
end

if saveOutput == 1
    save([save_string filename '.mat'],'best_obj','aperture','big_obj','initial_aperture','fourier_error','S');
end

%% Function for converting positions from experimental geometry to pixel geometry

    function [positions, bigx, bigy] = convert_to_pixel_positions(positions,pixel_size,little_area)
        positions = positions./pixel_size;
        positions(:,1) = (positions(:,1)-min(positions(:,1)));
        positions(:,2) = (positions(:,2)-min(positions(:,2)));
        positions(:,1) = (positions(:,1)-round(max(positions(:,1))/2));
        positions(:,2) = (positions(:,2)-round(max(positions(:,2))/2));
        positions = round(positions);
        bigx =little_area + max(positions(:))*2+10; % Field of view for full object
        bigy = little_area + max(positions(:))*2+10;
        big_cent = floor(bigx/2)+1;
        positions = positions+big_cent;
        
        
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

%% 2D guassian smoothing of an image

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
        if sum(hue(:)) == 0
            
        else
            hue = (hue./max(hue(:)));
        end
        value = (value./max(value(:))).*factor;
        hsv_obj(:,:,1) = hue;
        hsv_obj(:,:,3) = value;
        hsv_obj(:,:,2) = ones(sizey,sizex);
        hsv_obj = hsv2rgb(hsv_obj);
    end
%% Function for defining a specific region of an image

    function [roi, bigy, bigx] = get_roi(image, centrex,centrey,crop_size)
        
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
    function kspace = my_fft(rspace)
        %MY_FFT computes the FFT of an image
        %
        %   last modified 1/12/17
        
        kspace = fftshift(fftn(rspace));
    end
%% Inverse Fast Fourier transform function
    function rspace = my_ifft(kspace)
        %MY_IFFT computes the IFFT of an image
        %
        %   last modified 1/12/17
        
        rspace = ifftn(ifftshift(kspace));
    end
end


