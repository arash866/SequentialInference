%%
% This example covers general usage of this infinite Gaussian mixture model
% spike sorting code.  Neither this nor the provided code are in any way
% production code.  Usage of this code requires a few functions from the
% matlab statistics toolbox.  Use this code at your own risk but reference
% my work please.
%
% Copyright 2008, Author: Frank Wood, fwood@gatsby.ucl.ac.uk

% Since I can't provide real neural data I'm going to make some up and
% pretend that it's real, going step by step through many of the processes
% one probably will need to go through in a real situation.

% let's generate data from some unknown number of neurons
%randn('seed',0);
GIBBS = 0;
load times_CSC4;

inspk=inspk(:,1:10);%[1,3]);
inspk=inspk(1:1:size(inspk,1),:);

%%Normalizing data
for i=1:size(inspk,2)
    inspk(:,i) = (inspk(:,i)-mean(inspk(:,i)))/std(inspk(:,i));
end

reduced_dimensionality_waveforms = inspk;
spike_dimensions_to_retain = size(inspk,2);
number_of_spikes = size(inspk,1);

% OK, now we have reduced_dimensionality_waveforms.  Let's set up the
% priors for model estimation.  In this case we have the advantage of
% knowing the hyperparameters used in generating the data (and that the
% data truly comes from a mixture of gaussians model), but let's say we
% didn't.  The model requires us to specify:
%
%   \Lambda_0^{-1} : our prior for per-neuron spike variability about it's
%                    mean spike
%   v_0 : how much confidence we have in this prior (must be greater than
%   spike_dimensions_to_retain for mathematical reasons)
%   mu_0 : the mean waveform for a particular cell
%   k_0 : how much confidence we have in this prior
%   a_0, b_0 : gamma(a_0, b_0) on the CRP concentration parameter alpha
%
% Even though these parameters have reasonably clear interpretations, it still 
% can be difficult to hand-specify them (although this is really the way they should
% be specified, i.e. carefully designed to match your understanding about how much 
% variability spike waveform shape has, etc.  If you don't want to go through with this
% reasonable heuristic fall-back is to repeatedly sample from the model's
% prior until the samples "look like" your data.  I _highly_ recommend that
% you run the section below many, many times to develop an intuition for
% how the model hyperparameters affect things.  Run it multiple times for
% the same hyperparameter values to see the "distribution," then change
% hyperparameter values and do it again to gauge the effect of different
% hyperparameters on the prior.
%%%%%%%%%%%%%%% REPEAT THIS
%% 
mu_0 = zeros(spike_dimensions_to_retain,1);
k_0 = 0.01;%.05;
lambda_0 = eye(spike_dimensions_to_retain)*3;%1.5;


v_0 = spike_dimensions_to_retain+1;%5
a_0 = 1;
b_0 = 1;
[samples labels means covariances] = sample_igmm_prior(number_of_spikes,a_0,b_0,mu_0,lambda_0,k_0,v_0);

%figure(2) 
%scatter(samples(:,1),samples(:,2),[],labels);
%%%%%%%%%%%%%%% END REPEAT

in_sample_points = 1000;%number_of_spikes;
in_sample_training_data = reduced_dimensionality_waveforms(1:in_sample_points,:);
out_of_sample_training_data = reduced_dimensionality_waveforms(in_sample_points+1:end,:);

if GIBBS == 1
    %%
    % once you have hyperparameters that work for your data it's time to start model
    % estimation.  Usually there is too much data so some subsampling of the
    % data is done.  Here we'll take the first 1000 datapoints to start model
    % estimation.  Doing this is _not necessary_ and particle filter estimation
    % can be used from the start, but doing this makes it easier to debug the
    % spike sorter
    in_sample_points = 1000;%number_of_spikes;
    in_sample_training_data = reduced_dimensionality_waveforms(1:in_sample_points,:);
    %% do not have in_sample_training_data_labels = class_labels(1:in_sample_points,:);
    out_of_sample_training_data = reduced_dimensionality_waveforms(in_sample_points+1:end,:);
    %% do not have out_of_sample_training_data_labels = class_labels(in_sample_points+1:end,:);

    % num_sweeps is the number of steps in the Gibbs sampler.  The sampler
    % should be run to convergence.  Convergence of MCMC methods is very
    % difficult to assess automatically -- visually checking that the
    % model_scores have stabilized is the practical way to do it
    num_sweeps = 200;
    trace_plot_number = 3;
    progress_plot_number = 4;
    alpha_0 = 1; 
    [class_id_samples, num_classes_per_sample, model_scores, alpha_record] = collapsed_gibbs_sampler(...
        in_sample_training_data', num_sweeps, a_0, b_0, mu_0, k_0, v_0, ...
        lambda_0, alpha_0, trace_plot_number, progress_plot_number);

    % "samples" from before the sampler has burned in are _not_ samples, they
    % are _garbage_.  Samples from the burn-in period _must_ be thrown away
    burned_in_index = 51;
    class_id_samples = class_id_samples(:,burned_in_index:end);
    num_classes_per_sample = num_classes_per_sample(burned_in_index:end);
    model_scores = model_scores(burned_in_index:end);
    alpha_record = alpha_record(burned_in_index:end);

    % at this point, if we want, we can run some diagnostics to see whether or
    % not the model is doing what we want it to do, for instance, we can check
    % out the estimated marginal distribution over the number of neurons
    figure(5)
    histogram = histc(num_classes_per_sample,1:21-.5);
    bar(1:20,histogram);
    lh = line([4 4],[0 max(histogram)+1]);
    set(lh,'Color',[0 1 0],'LineWidth',2);
    title('Estimated distribution over number of neurons')
    legend(lh,'True # neurons')
end

% realize that class_id_samples is a collection of equally weighted spike
% sortings. The model_scores are proportional to the log probability of the
% model given the data.

% now that we have handled all of the "in-sample" datapoints, we now should
% integrate the "out of sample" waveforms.  We could  just as well run the 
% Gibbs sampler again, but this time with all of the waveforms instead of 
% just the first "in-sample" datapoints.  Instead to do this we switch to
% sequential posterior estimation through particle filtering.
% *Important note* -- the next two lines of code are tied fairly tightly to
% the previous code.  If you want to disconnect the particle filter from the Gibbs
% sampler in order to run only the particle filter then num_particles can
% be set to any value (higher is good, infinite is exact).  The particle
% filter suffers from one drawback, namely, alpha is instead
% treated as a parameter instead of a random variable.  This is a difficult 
% technical issue.
num_particles = 50;%num_sweeps-burned_in_index+1;
[spike_sortings, spike_sorting_weights, number_of_neurons_in_each_sorting, PF_means, PF_sum_squares, PF_inv_cov, PF_log_det_cov, PF_counts] = particle_filter(in_sample_training_data', ...
    num_particles, a_0, b_0, mu_0, k_0, v_0, ...
    lambda_0,1);
    %lambda_0,mean(alpha_record), class_id_samples);
    



% You're done!  Now all of the data has been integrated into the model as we now have 
% (weighted) set of sampled spike sortings.  Now comes the hard part.  One
% can simply take the MAP spike sorting (spike sorting with the highest
% weight) but that throws away basically the entire point of having gone
% through all of this in the first point.  Instead, analyses should be run
% on all spike sortings and then averaged: something like this:

% for n=1:num_particles
%     result(n) = perform_averagable_analysis(spike_sorting(n),
%     per_spike_side_information_like_spike_timing_and_or_stimulus);
% end
% average_result = result.*spike_sorting_weights;

% just for the fun of it though, let's look at the MAP sample
map_spike_sorting_index = find(spike_sorting_weights == max(spike_sorting_weights),1);
map_spike_sorting = spike_sortings(map_spike_sorting_index,:);
figure(6)
scatter(in_sample_training_data(:,1),in_sample_training_data(:,2),[],map_spike_sorting);
title('MAP Spike sorting')
% if you compare this to figure 1 you will notice that the colors assigned
% to each class are probably different -- that's because the distribution
% is invariant to permutations of the labeling (the labeling of which
% neuron each spike is attributed to).  This is _extremely consequential_
% to the design of analyses that use the entire posterior distribution.
% Although it may _happen_ that all of the spike sortings have roughly the
% same labeling scheme, that is definitely _not_ something you should ever
% count on in the use of this spike sorting technique

% and we can repeat neuron cardinality analysis, but this time for weighted
% samples
E_number_of_neurons = sum(double(number_of_neurons_in_each_sorting) .* spike_sorting_weights);
MAP_number_of_neurons = number_of_neurons_in_each_sorting(map_spike_sorting_index);
disp(['Expected number of neurons (' num2str(E_number_of_neurons) ') vs. MAP number of neurons (' num2str(MAP_number_of_neurons) ')'])


% Plotting 
if 1==0
    %colors = ['r' 'b' 'm' 'g' 'y' 'm' 'y' 'b' 'r' 'g' 'k' 'm' 'y' 'b'];
    colors={};
    DIV=size(unique(map_spike_sorting),2);
    elm = [1:255/DIV:255];
    elm=elm/255;

    colors{1}=[0.8 0 0]; colors{2} = [0 0.8 0]; colors{3} = [0 0 0.8]; colors{4} = [0.8 0.8 0.2];
    colors{5} = [0.2 0.4 0.3]; colors{6} = [1 1 1];

    for i=1:DIV
        colors{i} = colors{i};
    end

    figure(7)
    for i=1:size(map_spike_sorting,2)
       plot(spikes(i,:),'Color', colors{map_spike_sorting(i)});hold all; 
    end


    %selective plot
    for ii=0:length(unique(map_spike_sorting))
        figure(8+ii)
        for i=1:size(map_spike_sorting,2)
            if map_spike_sorting(i) == ii
                plot(spikes(i,:),'Color', colors{map_spike_sorting(i)});hold all; 
            end
        end
    end
end

%% Calculate Held out likelihood

pc_max_ind = 1e5;
pc_gammaln_by_2 = 1:pc_max_ind;
pc_gammaln_by_2 = gammaln(pc_gammaln_by_2/2);
pc_log_pi = reallog(pi);
pc_log = reallog(1:pc_max_ind);

inv_Sigma = PF_inv_cov;
log_det_Sigma = PF_log_det_cov;
    
for index=1:size(spike_sortings,1)
    
    index = map_spike_sorting_index;
    
    heldout_loglikelihood = 0;
    K = number_of_neurons_in_each_sorting(index);%MAP_number_of_neurons;
    for i=1:size(out_of_sample_training_data, 1)
        y = out_of_sample_training_data(i,:)';
        for kid=1:K %Integrating cluster assigments
            n = length(find(spike_sortings(index,:) ==kid ));%length(find(map_spike_sorting==kid)); 
            m_Y = PF_means(:,kid, index,1);%map_spike_sorting_index,1);
            SS=PF_sum_squares(:,:,kid,index,1);%map_spike_sorting_index,1);
            [lp ldc ic] = lp_tpp_helper(pc_max_ind,pc_gammaln_by_2,pc_log_pi,pc_log,y,n,m_Y,SS,k_0,mu_0,v_0,lambda_0);%, log_det_Sigma, inv_Sigma);
            heldout_loglikelihood = heldout_loglikelihood + lp;
        end
    end
    index
    heldout_loglikelihood
    disp('------------');
    %lp_mvniw(map_spike_sorting(:,1001:8195),inspk(1001:9195,:)', mu_0, k_0,3,lambda_0)
    
    return
end