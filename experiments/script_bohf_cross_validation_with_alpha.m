
% SCRIPT_BOHF_WITH_ALPHA_CROSS_VALIDATION
% -------------------------------------------------------------------------
% This script performs a full evaluation of the BOHF model on a given set.
% -------------------------------------------------------------------------

config_bohf_cross_validation;
alphas_exp = 1:10;

%% preset variables 

% set the random seed for k-means
rng(7);

% set the data path
input_data_path = fullfile(input_data_path, database);
% and the path for images
images_folder = fullfile(input_data_path, 'images');
% and the path with the hemodynamic simulations
simulations_path = fullfile(input_data_path, 'hemodynamic-simulation');


% load the labels
load(fullfile(input_data_path, 'labels.mat'));

% retrieve image filenames
image_filenames = dir(fullfile(images_folder, '*.png'));
image_filenames = { image_filenames.name };

% retrieve the simulation filenames
feature_map_filenames = dir(fullfile(simulations_path, strcat('*_', simulation_scenario, '_sol.mat')));
feature_map_filenames = { feature_map_filenames.name };

% retrieve the cnn features, if necessary
% set the path for collecting pre-computed features
cnn_features_path = fullfile(input_data_path, cnn_features);
cnn_features_filenames = dir(fullfile(cnn_features_path, strcat('*-', type_of_feature, '.mat')));
cnn_features_filenames = { cnn_features_filenames.name };


% lets use leave-one-out cross-validation
data_partition = cvpartition(length(feature_map_filenames), 'LeaveOut');

%% run cross validation!!

% initialize the array of scores for collecting each probability
scores = zeros(data_partition.NumTestSets, 1);
y_hat = zeros(data_partition.NumTestSets, 1);

% iterate for each partition
for i = 1 : data_partition.NumTestSets
    
    fprintf( '========= Fold %d/%d =========\n', i, data_partition.NumTestSets);
    
    % separate the training and validation
    
    % collect the indices of the original training samples and randomly
    % shuffle them
    original_training_idx = find(data_partition.training(i));
    original_training_idx = original_training_idx(randperm(length(original_training_idx)));
    original_training_labels = labels(original_training_idx);
    % identify the labels
    unique_labels = unique(original_training_labels);
    % initialize the training and validation sets
    current_training_set = zeros(length(data_partition.training(i)), 1);
    current_validation_set = zeros(length(data_partition.training(i)), 1);
    
    % ensure a similar distribution of each sample
    for l_id = 1 : length(unique_labels)
       
        % get the training idx associated with current label
       current_labels_original_training_idx = original_training_idx(original_training_labels == unique_labels(l_id));
       % 70% will be used for training
       n_training_samples = floor(length(current_labels_original_training_idx) * 0.7);       
       % use the first n_training_samples for training
       current_training_set(current_labels_original_training_idx(1:n_training_samples)) = 1;
       % and the remaining for validation
       current_validation_set(current_labels_original_training_idx(n_training_samples+1:end)) = 1;
    end
    % turn it to logical
    current_training_set = current_training_set > 0;
    current_validation_set = current_validation_set > 0;
    
    % divide data into training 
    training_samples = feature_map_filenames(current_training_set);
    training_cnn_samples = cnn_features_filenames(current_training_set);
    training_labels = labels(current_training_set);
    % ... validation
    validation_samples = feature_map_filenames(current_validation_set);
    validation_cnn_samples = cnn_features_filenames(current_validation_set);
    validation_labels = labels(current_validation_set);
    % and test
    test_samples = feature_map_filenames(data_partition.test(i));
    test_cnn_samples = cnn_features_filenames(data_partition.test(i));
    test_labels = labels(data_partition.test(i));
    
    % identify the test index
    test_index = find(data_partition.test(i));
    
    % initialize the array of models for evaluating different k values
    models_for_each_k = cell(length(ks), length(alphas_exp));
    validation_performance = zeros(length(ks), length(alphas_exp));
    
    % try different k values
    for j = 1 : length(ks)
    
        k = ks(j);
        disp(['Trying with k=', num2str(k)]);
        
        % train the bag of hemodynamic features extractor
        %disp('Identifying centroids');
        centroids = get_hemodynamic_centroids( simulations_path, training_samples, training_labels, k );

        if any(isnan(centroids(:)))
            disp('Skipping this k because it generates unvalid clusters');
            break
        end
        
        % compute features for the training set based on these centroids
        %disp('Extracting features on the training set');
        training_features = extract_bag_of_hemodynamic_features( simulations_path, training_samples, centroids, '', false );
        %disp('Extracting features on the validation set');
        validation_features = extract_bag_of_hemodynamic_features( simulations_path, validation_samples, centroids, '', false );
        
        % compact all the training features
        %disp('Collecting all the training features within a single design matrix X');
        X = compact_features(training_features);
        size_bohf = size(X,2);
        X = cat(2, X, retrieve_cnn_features( cnn_features_path, training_cnn_samples ));

        % normalize the features
        training_mean = mean(X);
        training_std = std(X) + eps;
        X = bsxfun(@rdivide, bsxfun(@minus, X, training_mean), training_std);
        
        % normalize all the validation features
        X_val = compact_features(validation_features);
        X_val = cat(2, X_val, retrieve_cnn_features( cnn_features_path, validation_cnn_samples ));
        X_val = bsxfun(@rdivide, bsxfun(@minus, X_val, training_mean), training_std);
        
        % iterate for each alpha value
        alpha_performance = zeros(10, 1);       
        for alpha_pow = 1 : 10
            
            % compute the alpha
            alpha = 1 / 2^alpha_pow;
            
            % balance the features
            X(:,1:size_bohf) = alpha * X(:,1:size_bohf);
            X(:,size_bohf+1:end) = (1 - alpha) * X(:,size_bohf+1:end);
            
            X_val(:,1:size_bohf) = alpha * X_val(:,1:size_bohf);
            X_val(:,size_bohf+1:end) = (1 - alpha) * X_val(:,size_bohf+1:end);
            
            % train a classifier
            switch classifier

                case 'random-forest'
                    % train a random forest
                    %fprintf('Training random forest classifier\n');
                    model = train_random_forest(X, training_labels);
                    model.training_mean = training_mean;
                    model.training_std = training_std;
                    model.centroids = centroids;
                    model.alpha = alpha;
                    % evaluate it
                    [val_scores, val_yhat] = classRF_predict_probabilities(X_val, model);

                case 'logistic-regression'

                    % train a logistic regression classifier
                    model = train_logistic_regression_classifier(X, training_labels, X_val, validation_labels, validation_metric);
                    model.training_mean = training_mean;
                    model.training_std = training_std;
                    model.centroids = centroids;
                    model.alpha = alpha;
                    % evaluate it
                    [val_scores, val_yhat] = predict_with_logistic_regression(X_val, model);

                otherwise
                    error('Unsuported classifier. Please, use random-forest');
            end

            switch validation_metric
                case 'auc'
                    % get the AUC value
                    [~,~,info] = vl_roc( 2*validation_labels-1, val_scores);
                    disp(['--> AUC = ', num2str(info.auc)]);
                    current_performance = info.auc;
                case 'acc'
                    current_performance = sum(val_yhat==validation_labels) / length(val_yhat);
                    disp(['--> Acc = ', num2str(current_performance)]);
            end
            
            % store current performance
            alpha_performance(alpha_pow) = current_performance;
             
            % collect the model
            models_for_each_k{j,alpha_pow} = model;
            % skip the search if a high value has been already found
            if (current_performance==1)
                validation_performance(j,alpha_pow) = current_performance;
                disp('Skipping the other k values as we have already found a maximum');
                break
            else
                validation_performance(j,alpha_pow) = current_performance;
            end
            
        end
        
    end
    
    % pick the best mode    
    [best_val_performance, idx] = max(validation_performance(:));
    [idx_i, idx_j] = ind2sub(size(validation_performance), idx);
    model = models_for_each_k{idx_i, idx_j};
    k_best = ks(idx_i, idx_j);
    disp(['Best model for k=', num2str(k_best), ' and alpha=', num2str(model.alpha), ' (', validation_metric, '=', num2str(best_val_performance), ')']);
        
    %disp('Extracting features on the test set');
    test_features = extract_bag_of_hemodynamic_features( simulations_path, test_samples, model.centroids, '', false );
    
    % normalize all the test features
    X_test = compact_features(test_features);
    if add_cnn_features
        X_test = cat(2, X_test, retrieve_cnn_features( cnn_features_path, test_cnn_samples ));
    end 
    X_test = bsxfun(@rdivide, bsxfun(@minus, X_test, model.training_mean), model.training_std);
    
    % evaluate the classifier
    switch classifier
        
        case 'random-forest'
            % evaluate it
            [scores(test_index), y_hat(test_index)] = classRF_predict_probabilities(X_test, model);
            
        case 'logistic-regression'
            % evaluate it
            [scores(test_index), y_hat(test_index)] = predict_with_logistic_regression(X_test, model);
            
        otherwise
            error('Unsuported classifier. Please, use random-forest or logistic-regression');
    end
    
end


switch classifier
    case 'logistic-regression'
        scores = exp(scores) ./ (1 + exp(scores));
end
        
% get the ROC curve
[TPR,TNR,info] = vl_roc( 2*labels-1, scores);
% plot it
if ~exist('h', 'var')
    h = figure;
    my_legends = { [classifier, ' - AUC=', num2str(info.auc)] };
else
    hold on;
    my_legends = cat(1, my_legends, { [classifier, ' - AUC=', num2str(info.auc)] });
end
plot(1-TNR, TPR, 'LineWidth', 2)
legend(my_legends, 'Location', 'southeast');
xlabel('FPR (1 - Specificity)')
ylabel('TPR (Sensitivity)')
grid on
box on

fprintf('=================================\n');
fprintf('AUC = %d\n', info.auc);
fprintf('Acc = %d\n', sum(y_hat == labels)/length(y_hat));

%% save the results

% rename scores variable
all_scores = scores;
% create a tag for the experiment
if add_cnn_features
    output_tag = strcat('combined-', classifier, '-', cnn_features, '-', type_of_feature);
else
    output_tag = strcat('bohf-', classifier);
end
% update the output path
output_data_path = fullfile(output_data_path, database, output_tag);
mkdir(output_data_path);
% save each score separately
for i = 1 : length(image_filenames)
    scores = all_scores(i);
    current_filename = image_filenames{i};
    save(fullfile(output_data_path, strcat(current_filename(1:end-3), 'mat')), 'scores');
end