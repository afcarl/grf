#' Quantile forest
#' 
#' Trains a regression forest that can be used to estimate
#' quantiles of the conditional distribution of Y given X = x.
#'
#' @param X The covariates used in the quantile regression.
#' @param Y The outcome.
#' @param quantiles Vector of quantiles used to calibrate the forest.
#' @param regression.splitting Whether to use regression splits when growing trees instead
#'                             of specialized splits based on the quantiles (the default).
#'                             Setting this flag to true corresponds to the approach to
#'                             quantile forests from Meinshausen (2006).
#' @param sample.fraction Fraction of the data used to build each tree.
#'                        Note: If honesty is used, these subsamples will
#'                        further be cut in half.
#' @param mtry Number of variables tried for each split.
#' @param num.trees Number of trees grown in the forest. Note: Getting accurate
#'                  confidence intervals generally requires more trees than
#'                  getting accurate predictions.
#' @param num.threads Number of threads used in training. If set to NULL, the software
#'                    automatically selects an appropriate amount.
#' @param min.node.size A target for the minimum number of observations in each tree leaf. Note that nodes
#'                      with size smaller than min.node.size can occur, as in the original randomForest package.
#' @param honesty Whether or not honest splitting (i.e., sub-sample splitting) should be used.
#' @param alpha A tuning parameter that controls the maximum imbalance of a split.
#' @param imbalance.penalty A tuning parameter that controls how harshly imbalanced splits are penalized.
#' @param seed The seed for the C++ random number generator.
#' @param clusters Vector of integers or factors specifying which cluster each observation corresponds to.
#' @param samples_per_cluster If sampling by cluster, the number of observations to be sampled from
#'                            each cluster. Must be less than the size of the smallest cluster. If set to NULL
#'                            software will set this value to the size of the smallest cluster.
#'
#' @return A trained quantile forest object.
#'
#' @examples \dontrun{
#' # Generate data.
#' n = 50; p = 10
#' X = matrix(rnorm(n*p), n, p)
#' X.test = matrix(0, 101, p)
#' X.test[,1] = seq(-2, 2, length.out = 101)
#' Y = X[,1] * rnorm(n)
#' 
#' # Train a quantile forest.
#' q.forest = quantile_forest(X, Y, quantiles=c(0.1, 0.5, 0.9))
#' 
#' # Make predictions.
#' q.hat = predict(q.forest, X.test)
#' 
#' # Make predictions for different quantiles than those used in training.
#' q.hat = predict(q.forest, X.test, quantiles=c(0.1, 0.9))
#' 
#' # Train a quantile forest using regression splitting instead of quantile-based
#' # splits, emulating the approach in Meinshausen (2006).
#' meins.forest = quantile_forest(X, Y, regression.splitting=TRUE)
#' 
#' # Make predictions for the desired quantiles.
#' q.hat = predict(meins.forest, X.test, quantiles=c(0.1, 0.5, 0.9))
#' }
#' 
#' @export
quantile_forest <- function(X, Y, quantiles = c(0.1, 0.5, 0.9), regression.splitting = FALSE,
                            sample.fraction = 0.5, mtry = NULL, num.trees = 2000,
                            num.threads = NULL, min.node.size = NULL, honesty = TRUE,
                            alpha = 0.05, imbalance.penalty = 0.0, seed = NULL,
                            clusters = NULL, samples_per_cluster = NULL) {
    if (!is.numeric(quantiles) | length(quantiles) < 1) {
        stop("Error: Must provide numeric quantiles")
    } else if (min(quantiles) <= 0 | max(quantiles) >= 1) {
        stop("Error: Quantiles must be in (0, 1)")
    }
    
    validate_X(X)
    if(length(Y) != nrow(X)) { stop("Y has incorrect length.") }
    
    mtry <- validate_mtry(mtry, X)
    num.threads <- validate_num_threads(num.threads)
    min.node.size <- validate_min_node_size(min.node.size)
    sample.fraction <- validate_sample_fraction(sample.fraction)
    seed <- validate_seed(seed)
    clusters <- validate_clusters(clusters, X)
    samples_per_cluster <- validate_samples_per_cluster(samples_per_cluster, clusters)
    
    data <- create_data_matrices(X, Y)
    outcome.index <- ncol(X) + 1

    ci.group.size <- 1
    
    forest <- quantile_train(quantiles, regression.splitting, data$default, data$sparse,
        outcome.index, mtry, num.trees, num.threads, min.node.size, sample.fraction, seed,
        honesty, ci.group.size, alpha, imbalance.penalty, clusters, samples_per_cluster)
    
    forest[["X.orig"]] <- X
    forest[["clusters"]] <- clusters
    
    class(forest) <- c("quantile_forest", "grf")
    forest
}

#' Predict with a quantile forest
#' 
#' Gets estimates of the conditional quantiles of Y given X using a trained forest.
#'
#' @param object The trained forest.
#' @param newdata Points at which predictions should be made. If NULL,
#'                makes out-of-bag predictions on the training set instead
#'                (i.e., provides predictions at Xi using only trees that did
#'                not use the i-th training example).
#' @param quantiles Vector of quantiles at which estimates are required.
#' @param num.threads Number of threads used in training. If set to NULL, the software
#'                    automatically selects an appropriate amount.
#' @param ... Additional arguments (currently ignored).
#'
#' @return Predictions at each test point for each desired quantile.
#'
#' @examples \dontrun{
#' # Train a quantile forest.
#' n = 50; p = 10
#' X = matrix(rnorm(n*p), n, p)
#' Y = X[,1] * rnorm(n)
#' q.forest = quantile_forest(X, Y, quantiles=c(0.1, 0.5, 0.9))
#'
#' # Predict on out-of-bag training samples.
#' q.pred = predict(q.forest)
#'
#' # Predict using the forest.
#' X.test = matrix(0, 101, p)
#' X.test[,1] = seq(-2, 2, length.out = 101)
#' q.pred = predict(q.forest, X.test)
#' }
#'
#' @export
predict.quantile_forest <- function(object,
                                    newdata = NULL,
                                    quantiles = c(0.1, 0.5, 0.9),
                                    num.threads = NULL, ...) {
    
    if (!is.numeric(quantiles) | length(quantiles) < 1) {
        stop("Error: Must provide numeric quantiles")
    } else if (min(quantiles) <= 0 | max(quantiles) >= 1) {
        stop("Error: Quantiles must be in (0, 1)")
    }
    
    num.threads <- validate_num_threads(num.threads)
    
    forest.short <- object[-which(names(object) == "X.orig")]
    
    if (!is.null(newdata)) {
        data <- create_data_matrices(newdata)
        quantile_predict(forest.short, quantiles, data$default, data$sparse, num.threads)
    } else {
        data <- create_data_matrices(object[["X.orig"]])
        quantile_predict_oob(forest.short, quantiles, data$default, data$sparse, num.threads)
    }
}
