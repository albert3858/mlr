#' @title Update a model
#'
#' @description
#' Update a fitted model with new data.
#' The row names of the input \code{task} or \code{newdata} are preserved in the output.
#'
#' @param object [\code{\link{WrappedModel}}]\cr
#'   Wrapped model, result of \code{\link{train}}.
#' @param task [\code{\link{Task}}]\cr
#'   The task.
#' @param newdata [\code{data.frame}]\cr
#'   New observations to update the model
#' @param weights [\code{numeric}]\cr
#'   Optional, non-negative case weight vector to be used during fitting.
#'   If given, must be of same length as \code{subset} and in corresponding order.
#'   By default \code{NULL} which means no weights are used unless specified in the task (\code{\link{Task}}).
#'   Weights from the task will be overwritten.
#' @template arg_subset
#' @param ... [any]\cr
#'   Currently ignored.
#' @return [\code{\link{WrappedModel}}].
#' @export
#' @examples
#' dat <- arima.sim(model = list(ar = c(.5,.2), ma = c(.4), order = c(2,0,1)), n = 100)
#' times <- (as.POSIXlt("1992-01-14")) + lubridate::days(1:100)
#' dat <- xts::xts(dat,order.by = times, frequency = 1L)
#' colnames(dat) <- c("arma_test")
#' Timeregr.task = makeForecastRegrTask(id = "test", data = dat,
#' target = "arma_test", frequency = 1L)
#' arm = makeLearner("fcregr.Arima", h = 1)
#' trn = train(arm,Timeregr.task, subset = 1:99)
#' armNew =updateModel(trn, Timeregr.task, newdata = dat[100,])
updateModel = function(object, task, newdata, subset, weights = NULL, ...){

  #if (!xor(missing(task), missing(newdata)))
  #  stop("Pass either a task object or a newdata data.frame to predict, but not both!")
  assertClass(object, classes = "WrappedModel")
  model = object
  learner = model$learner
  td = model$task.desc

  if (missing(newdata))
    stop("No new data supplied")

  if (xts::is.xts(newdata))
    newdata = data.frame(row.names = index(newdata), newdata)
  assertDataFrame(newdata, min.rows = 1L)
  size = nrow(newdata)
  # FIXME: cleanup if cases
  if (missing(newdata)) {
    assertClass(task, classes = "Task")
    size = getTaskSize(task)
  } else {
    ##FIXME: Better way to make into a data frame? This doesn't protect against a lot of things
    if (xts::is.xts(newdata))
      newdata = as.data.frame(newdata)
    assertDataFrame(newdata, min.rows = 1L)
    size = nrow(newdata)
  }
  if (missing(subset)) {
    subset = seq_len(size)
  } else {
    if (is.logical(subset))
      subset = which(subset)
    else
      subset = asInteger(subset, min.len = 1L, any.missing = FALSE, lower = 1L, upper = size)
  }
  if (missing(newdata)) {
    newdata = getTaskData(task, subset)
  } else {
    newdata = newdata[subset,, drop = FALSE]
  }

  # if we saved a model and loaded it later just for prediction this is necessary
  requireLearnerPackages(learner)
  t.col = match(td$target, colnames(newdata))

  # get truth and drop target col, if target in newdata
  if (!all(is.na(t.col))) {
    if (length(t.col) > 1L && anyMissing(t.col))
      stop("Some but not all target columns found in data")
    truth = newdata[, t.col, drop = TRUE]
    if (is.list(truth))
      truth = data.frame(truth)
    #FIXME: Patchjob, need to find a way to identify that new data can be same as y.
    if (learner$type != "fcregr" && learner$type != "mfcregr")
      newdata = newdata[, -t.col, drop = FALSE]
  } else {
    truth = NULL
  }

  error = NA_character_
  # was there an error in building the model? --> return NAs
  if (isFailureModel(model)) {
    p = predictFailureModel(model, newdata)
    time.predict = NA_real_
  } else {
    #FIXME: this copies newdata
    pars = list(
      .learner = learner,
      .model = model,
      .newdata = newdata,
      .task = task
    )
  }


  # FIXME: code is bad here, set weights, the simply check it in checktasklearner
  if (!is.null(weights)) {
    assertNumeric(weights, len = length(subset), any.missing = FALSE, lower = 0)
  } else {
    weights = getTaskWeights(task)
  }

  checkLearnerBeforeTrain(task, learner, weights)
  pars$.weights = weights

  # only pass train hyper pars as basic rlearner in ...
  pars = c(pars, getHyperPars(learner, c("train", "both")))

  vars = getTaskFeatureNames(task)
  # no vars? then use no vars model

  if (length(vars) == 0L && learner$type != "fcregr") {
    learner.model = makeNoFeaturesModel(targets = task$env$data[subset, tn], task.desc = getTaskDescription(task))
    time.train = 0
  } else {
    opts = getLearnerOptions(learner, c("show.learner.output", "on.learner.error", "on.learner.warning"))
    # set the seed
    debug.seed = getMlrOption("debug.seed", NULL)
    if (!is.null(debug.seed))
      set.seed(debug.seed)
    # for optwrappers we want to see the tuning / varsel logging
    # FIXME: is case really ok for optwrapper? can we supppress then too?
    fun1 = if (opts$show.learner.output || inherits(learner, "OptWrapper")) identity else capture.output
    fun2 = if (opts$on.learner.error == "stop") identity else function(x) try(x, silent = TRUE)
    if (opts$on.learner.warning == "quiet") {
      old.warn.opt = getOption("warn")
      on.exit(options(warn = old.warn.opt))
      options(warn = -1L)
    }
    st = system.time(fun1(learner.model <- fun2(do.call(updateLearner2, pars))), gcFirst = FALSE)
    # was there an error during training? maybe warn then
    if (is.error(learner.model) && opts$on.learner.error == "warn")
      warningf("Could not train learner %s: %s", learner$id, as.character(learner.model))
    time.train = as.numeric(st[3L])
  }
  factor.levels = getTaskFactorLevels(task)
  makeWrappedModel(learner, learner.model, getTaskDescription(task), subset, vars, factor.levels, time.train)


}

#' Update an R learner with new data.
#'
#' Mainly for internal use. Update a model with new data.
#' You have to implement this method if you want to add another learner to this package.
#'
#' Your implementation must adhere to the following:
#' Updates to the observations in \code{.newdata} must be made based on the fitted
#' model (\code{.model$learner.model}).
#' All parameters in \code{...} must be passed to the underlying predict function.
#'
#' @param .learner [\code{\link{RLearner}}]\cr
#'   Wrapped learner.
#' @param .model [\code{\link{WrappedModel}}]\cr
#'   Model produced by training.
#' @param .newdata [\code{data.frame}]\cr
#'   New data to predict. Does not include target column.
#' @param ... [any]\cr
#'   Additional parameters, which need to be passed to the underlying predict function.
#' @return
#' \itemize{
#'   \item For classification: Either a factor with class labels for type
#'     \dQuote{response} or, if the learner supports this, a matrix of class probabilities
#'     for type \dQuote{prob}. In the latter case the columns must be named with the class
#'     labels.
#'   \item For regression or forecast regressions: Either a numeric vector for type \dQuote{response} or,
#'     if the learner supports this, a matrix with two columns for type \dQuote{se}.
#'     In the latter case the first column contains the estimated response (mean value)
#'     and the second column the estimated standard errors.
#'   \item For survival: Either a numeric vector with some sort of orderable risk
#'     for type \dQuote{response} or, if supported, a numeric vector with time dependent
#'     probabilities for type \dQuote{prob}.
#'   \item For clustering: Either an integer with cluster IDs for type \dQuote{response}
#'     or, if supported, a matrix of membership probabilities for type \dQuote{prob}.
#'   \item For multilabel: A logical matrix that indicates predicted class labels for type
#'     \dQuote{response} or, if supported, a matrix of class probabilities for type
#'     \dQuote{prob}. The columns must be named with the class labels.
#'  }
#' @export
updateLearner = function(.learner, .model, .newdata, ...) {
  lmod = getLearnerModel(.model)
  if (inherits(lmod, "NoFeaturesModel")) {
    predict_nofeatures(.model, .newdata)
  } else {
    if (.learner$type != "fcregr" && .learner$type != "mfcregr")
      assertDataFrame(.newdata, min.rows = 1L, min.cols = 1L)
    UseMethod("updateLearner")
  }
}


updateLearner2 = function(.learner, .model, .newdata, ...) {
  # if we have that option enabled, set factor levels to complete levels from task
  if (.learner$fix.factors.prediction) {
    fls = .model$factor.levels
    ns = names(fls)
    # only take objects in .newdata
    ns = intersect(colnames(.newdata), ns)
    fls = fls[ns]
    if (length(ns) > 0L)
      .newdata[ns] = mapply(factor, x = .newdata[ns],
                            levels = fls, SIMPLIFY = FALSE)
  }
  u = updateLearner(.learner, .model, .newdata, ...)
  #p = checkPredictLearnerOutput(.learner, .model, p)
  return(u)
}
