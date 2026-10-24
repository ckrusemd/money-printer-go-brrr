# Reproducible, bounded rolling-origin comparisons. No fitting at source time.
research_model_config <- function() list(schema=1L,trees=100L,min_origins=30L,
  minimum_skill=.05,review_origins=60L,seed=1971L,market_initial=756L,crypto_initial=1095L,
  construction_initial=120L,market_window=2520L,crypto_window=3650L,construction_window=240L)

research_gap <- function(d,as_of=book_date()) max(0L,
  12L*(lubridate::year(as_of)-lubridate::year(tail(d$date,1)))+
    lubridate::month(as_of)-lubridate::month(tail(d$date,1)))

research_model_signature <- function() book_hash(list(config=research_model_config(),
  code=lapply(c("research_models.R","research_math.R","research_data.R"),function(f) readLines(file.path("scripts/analysis",f))),
  lock=readLines("renv.lock")))

research_features <- function(y,monthly=FALSE,extra=NULL) {
  n<-length(y);lagged<-function(k) if(n>k)c(rep(NA_real_,k),head(y,-k)) else rep(NA_real_,n)
  logy<-if(monthly)log1p(y) else log(y)
  laglog<-function(k) if(n>k)c(rep(NA_real_,k),head(logy,-k)) else rep(NA_real_,n)
  if(monthly) {
    x<-data.frame(level=logy,lag1=laglog(1),lag3=laglog(3),lag12=laglog(12),
      season_sin=sin(2*pi*seq_len(n)/12),season_cos=cos(2*pi*seq_len(n)/12))
  } else {
    ret<-c(NA,diff(logy));vol<-vapply(seq_len(n),function(i)if(i>20)stats::sd(ret[(i-19):i]) else NA_real_,double(1))
    x<-data.frame(momentum5=logy-laglog(5),momentum20=logy-laglog(20),
      momentum63=logy-laglog(63),momentum252=logy-laglog(252),volatility20=vol)
  }
  if(!is.null(extra)) x<-cbind(x,extra)
  x
}

research_targets <- function(data) {
  assets<-data$assets[data$assets$kind%in%c("equity","crypto"),]
  out<-lapply(seq_len(nrow(assets)),function(i) list(id=assets$id[i],monthly=FALSE,
    horizons=if(assets$kind[i]=="crypto") c(7L,30L,90L,180L,365L) else c(5L,20L,63L,126L,252L),
    initial=if(assets$kind[i]=="crypto")1095L else 756L,
    stride=if(assets$kind[i]=="crypto")30L else 21L,
    unit=if(assets$kind[i]=="crypto")"calendar days" else "trading sessions"))
  for(type in c("10000","10300","10400")) out[[length(out)+1L]]<-list(
    id=paste0("dk_build_counts_",type,"_3"),monthly=TRUE,horizons=c(3L,6L,12L),initial=120L,stride=3L,unit="months")
  # Selected residential floor-area types are summed explicitly, not mixed with counts.
  area<-data$observations[grepl("^dk_build_area_(120|130|140)_3$",data$observations$id),]
  if(nrow(area)) out[[length(out)+1L]]<-list(id="dk_completed_area",monthly=TRUE,horizons=c(3L,6L,12L),initial=120L,stride=3L,unit="months")
  out
}

research_target_data <- function(data,spec) {
  if(spec$id=="dk_completed_area") {
    z<-data$observations[grepl("^dk_build_area_(120|130|140)_3$",data$observations$id),]
    z<-aggregate(value~date,z,sum);return(z[order(z$date),])
  }
  z<-research_series(data,spec$id);z[,c("date","value"),drop=FALSE]
}

research_training <- function(y,x,i,h,window,differences=FALSE) {
  # A target at j+h may only be used once that target is observed at origin i.
  rows<-seq_len(max(0L,i-h));rows<-rows[rows>=max(1L,i-window)]
  target<-if(length(rows)) y[rows+h] else numeric()
  if(differences&&length(rows))target<-target-y[rows]
  keep<-stats::complete.cases(x[rows,,drop=FALSE])&is.finite(target)
  list(x=x[rows[keep],,drop=FALSE],y=target[keep],rows=rows[keep])
}

research_predictions <- function(y,x,i,horizons,monthly,window,seed=1971L) {
  transformed<-if(monthly)log1p(y) else log(y)
  train<-transformed[seq.int(max(1L,i-window+1L),i)]
  out<-matrix(NA_real_,nrow=length(horizons),ncol=4L,
    dimnames=list(as.character(horizons),c("benchmark","drift_ets","arima","random_forest")))
  out[,"benchmark"]<-if(monthly) vapply(horizons,function(h)y[i-((12-h%%12)%%12)],double(1)) else y[i]
  arima<-tryCatch(forecast::auto.arima(stats::ts(train,frequency=if(monthly)12 else 1),
    max.p=2,max.q=2,max.P=1,max.Q=1,max.order=4,stepwise=TRUE,approximation=TRUE),error=function(e)NULL)
  if(!is.null(arima)) {
    p<-as.numeric(forecast::forecast(arima,h=max(horizons))$mean)[horizons]
    out[,"arima"]<-if(monthly)pmax(0,expm1(p)) else exp(p)
  }
  fit<-tryCatch(if(monthly)forecast::ets(stats::ts(train,frequency=12),model="ZZZ") else NULL,error=function(e)NULL)
  if(monthly&&!is.null(fit)) out[,"drift_ets"]<-pmax(0,expm1(as.numeric(forecast::forecast(fit,h=max(horizons))$mean)[horizons]))
  if(!monthly) out[,"drift_ets"]<-exp(tail(train,1)+mean(diff(train))*horizons)
  for(k in seq_along(horizons)) {
    h<-horizons[k];training<-research_training(transformed,x,i,h,window,differences=!monthly)
    if(nrow(training$x)<60L || !all(is.finite(as.numeric(x[i,])))) next
    set.seed(seed+h)
    fit<-tryCatch(randomForest::randomForest(x=training$x,y=training$y,ntree=research_model_config()$trees,
      mtry=min(3L,ncol(x)),nodesize=10L),error=function(e)NULL)
    if(!is.null(fit)) {
      p<-as.numeric(stats::predict(fit,x[i,,drop=FALSE]))
      out[k,"random_forest"]<-if(monthly)max(0,expm1(p)) else exp(transformed[i]+p)
    }
  }
  out
}

research_bootstrap_skill <- function(difference,seed=1971L,repetitions=399L,minimum_block=2L) {
  n<-length(difference);if(n<30) return(NA_real_)
  set.seed(seed);block<-min(n,max(minimum_block,ceiling(sqrt(n))))
  means<-replicate(repetitions,{
    starts<-sample.int(n,ceiling(n/block),replace=TRUE)
    ids<-unlist(lapply(starts,function(s)((s-1L+seq_len(block)-1L)%%n)+1L))[seq_len(n)]
    mean(difference[ids])
  })
  as.numeric(stats::quantile(means,.025,names=FALSE))
}

research_model_scores <- function(records) {
  if(!nrow(records)) return(data.frame())
  groups<-split(seq_len(nrow(records)),paste(records$id,records$horizon,records$model,sep="|"))
  do.call(rbind,lapply(groups,function(at) {
    d<-records[at,];d<-d[is.finite(d$actual)&is.finite(d$estimate),]
    if(!nrow(d))return(NULL)
    base<-records[records$id==d$id[1]&records$horizon==d$horizon[1]&records$model=="benchmark",]
    base<-base[match(d$origin,base$origin),]
    error<-d$estimate-d$actual;be<-abs(base$estimate-base$actual)
    skill<-1-mean(abs(error))/mean(be)
    stride<-if(nrow(d)>1L)stats::median(as.numeric(diff(sort(d$origin)))) else 1
    horizon_days<-stats::median(as.numeric(d$target_date-d$origin))
    lower<-research_bootstrap_skill(be-abs(error),minimum_block=max(2L,ceiling(horizon_days/max(1,stride))))
    cover80<-cover95<-rep(NA_real_,nrow(d))
    for(i in seq_len(nrow(d))) {
      # Only errors whose outcomes were available before this forecast origin
      # may calibrate that historical interval.
      available<-d$target_date+if(grepl("Retrospective",d$revision[1]))max(90L,31L*max(d$gap_months)) else 1L
      prior<-which(available<d$origin[i] & is.finite(d$actual)&d$actual>0&d$estimate>0)
      if(length(prior)<30L||d$actual[i]<=0||d$estimate[i]<=0)next
      monthly<-grepl("Retrospective",d$revision[1])
      residual<-if(monthly)log1p(d$actual[prior])-log1p(d$estimate[prior]) else log(d$actual[prior]/d$estimate[prior])
      q<-stats::quantile(residual,c(.025,.1,.9,.975),names=FALSE)
      r<-if(monthly)log1p(d$actual[i])-log1p(d$estimate[i]) else log(d$actual[i]/d$estimate[i])
      cover95[i]<-r>=q[1]&r<=q[4];cover80[i]<-r>=q[2]&r<=q[3]
    }
    data.frame(id=d$id[1],horizon=d$horizon[1],model=d$model[1],n=nrow(d),
      MAE=mean(abs(error)),RMSE=sqrt(mean(error^2)),bias=mean(error),
      MASE=if(all(d$scale>0))mean(abs(error)/d$scale) else NA_real_,
      relative_MAE=if(mean(be)>0)mean(abs(error))/mean(be) else NA_real_,skill=skill,skill_lower=lower,
      coverage80=if(all(is.na(cover80)))NA_real_ else mean(cover80,na.rm=TRUE),
      coverage95=if(all(is.na(cover95)))NA_real_ else mean(cover95,na.rm=TRUE),
      eligible=d$model[1]=="benchmark"||(nrow(d)>=30&&is.finite(skill)&&skill>=.05&&is.finite(lower)&&lower>0))
  }))
}

research_review <- function(data,output_dir=".cache/research-models",max_origins=research_model_config()$review_origins,
                            workers=as.integer(Sys.getenv("RESEARCH_WORKERS","2"))) {
  dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
  stopifnot(length(workers)==1L,is.finite(workers),workers>=1L,workers<=4L)
  signature<-research_model_signature()
  per_target<-function(spec) {
    records<-list()
    d<-research_target_data(data,spec);n<-nrow(d)
    if(n<spec$initial+min(spec$horizons)+1L)return(NULL)
    extra<-NULL
    if(spec$monthly) {
      extra<-data.frame(permits=rep(NA_real_,n),starts=rep(NA_real_,n))
      for(j in 1:2) {
        id<-sub("_3$",if(j==1)"_1" else "_2",spec$id)
        z<-research_series(data,id)
        if(nrow(z))extra[[j]]<-log1p(research_asof(d$date,z$date,z$value)) else extra[[j]]<-0
      }
    }
    x<-research_features(d$value,spec$monthly,extra)
    gap<-if(spec$monthly)research_gap(d) else 0L;hs<-spec$horizons+gap
    last<-n-min(hs);if(last<spec$initial)return(NULL)
    origins<-seq(spec$initial,last,by=spec$stride);origins<-tail(origins,max_origins)
    for(i in origins) {
      valid<-which(i+hs<=n);if(!length(valid))next
      key<-book_hash(list(signature=signature,id=spec$id,dates=d$date[seq_len(i+max(hs[valid]))],
        values=d$value[seq_len(i+max(hs[valid]))],features=x[seq_len(i),],origin=i,horizons=hs[valid]))
      file<-file.path(output_dir,paste0("fold-",key,".rds"))
      if(file.exists(file)) rows<-readRDS(file) else {
        window<-if(spec$monthly)240L else if(spec$unit=="calendar days")3650L else 2520L
        p<-research_predictions(d$value,x,i,hs[valid],spec$monthly,window)
        rows<-do.call(rbind,lapply(seq_along(valid),function(k) data.frame(id=spec$id,
          origin=if(spec$monthly)research_period_end(lubridate::add_with_rollback(d$date[i],lubridate::period(gap,"month")),"monthly") else d$date[i]+1L,target_date=d$date[i+hs[valid[k]]],
          horizon=spec$horizons[valid[k]],model=colnames(p),actual=d$value[i+hs[valid[k]]],estimate=as.numeric(p[k,]),
          gap_months=gap,scale=mean(abs(diff(head(d$value,i),lag=if(spec$monthly)12L else 1L))),
          revision=if(spec$monthly)"Retrospective: revised Danish inputs; conservative publication gap" else "Historical closing observations")))
        book_save_rds(rows,file)
      }
      records[[length(records)+1L]]<-rows
    }
    message("Reviewed ",spec$id," at ",length(origins)," origins")
    if(length(records))do.call(rbind,records) else NULL
  }
  targets<-research_targets(data)
  pieces<-if(workers>1L&&.Platform$OS.type=="unix")
    parallel::mclapply(targets,per_target,mc.cores=workers,mc.preschedule=FALSE) else lapply(targets,per_target)
  if(any(vapply(pieces,inherits,logical(1),"try-error")))stop("A model-review worker failed; no review promoted")
  records<-do.call(rbind,pieces);if(is.null(records))records<-data.frame()
  result<-list(schema=1L,signature=signature,review_date=book_date(),records=records,
    scores=research_model_scores(records),source_hash=book_hash(data$observations),config=research_model_config())
  book_save_rds(result,file.path(output_dir,"review.rds"));result
}

research_forecasts <- function(data,review=NULL) {
  if(is.null(review)&&file.exists(".cache/research-models/review.rds")) review<-readRDS(".cache/research-models/review.rds")
  valid_review<-is.list(review)&&identical(review$signature,research_model_signature())&&
    as.integer(book_date()-review$review_date)>=0L&&as.integer(book_date()-review$review_date)<=8L
  out<-list()
  for(spec in research_targets(data)) {
    d<-research_target_data(data,spec);n<-nrow(d);if(n<max(24L,spec$initial))next
    gap<-if(spec$monthly) research_gap(d) else 0L
    extra<-NULL
    if(spec$monthly) {
      extra<-data.frame(permits=rep(0,n),starts=rep(0,n))
      for(j in 1:2) {z<-research_series(data,sub("_3$",if(j==1)"_1" else "_2",spec$id));
        if(nrow(z))extra[[j]]<-log1p(research_asof(d$date,z$date,z$value))}
    }
    x<-research_features(d$value,spec$monthly,extra)
    p<-research_predictions(d$value,x,n,spec$horizons+gap,spec$monthly,
      if(spec$monthly)240L else if(spec$unit=="calendar days")3650L else 2520L)
    for(k in seq_along(spec$horizons)) {
      h<-spec$horizons[k];model<-"benchmark";evidence<-"Benchmark: no current validated review"
      target_review<-valid_review && (!spec$monthly || any(review$records$id==spec$id & review$records$gap_months==gap))
      scores<-if(target_review) review$scores else data.frame()
      if(nrow(scores)) {
        s<-scores[scores$id==spec$id & scores$horizon==h & scores$eligible,]
        s<-s[order(s$MAE),];if(nrow(s))model<-s$model[1]
        evidence<-if(model=="benchmark")"Benchmark retained: alternative skill not established" else "Alternative passed 5% MAE and bootstrap skill gates"
      }
      estimate<-p[k,model];if(!is.finite(estimate)){model<-"benchmark";estimate<-p[k,model];evidence<-"Benchmark: selected fit unavailable"}
      residual<-numeric()
      if(target_review&&nrow(review$records)) {
        r<-review$records;r<-r[r$id==spec$id&r$horizon==h&r$model==model&
          r$target_date<=book_date()&is.finite(r$estimate)&is.finite(r$actual),]
        residual<-if(spec$monthly)log1p(r$actual)-log1p(r$estimate) else log(r$actual/r$estimate)
      }
      bounds<-rep(NA_real_,4)
      if(length(residual)>=30) {
        q<-stats::quantile(residual,c(.025,.1,.9,.975),names=FALSE)
        bounds<-if(spec$monthly)pmax(0,expm1(log1p(estimate)+q)) else estimate*exp(q)
      }
      target_date<-if(spec$monthly)research_period_end(lubridate::add_with_rollback(lubridate::floor_date(book_date(),"month"),lubridate::period(h,"month")),"monthly") else
        if(spec$unit=="calendar days")tail(d$date,1)+h else as.Date(NA)
      out[[length(out)+1L]]<-data.frame(id=spec$id,origin=book_date(),last_observed=tail(d$date,1),
        target_date=target_date,horizon=h,horizon_unit=spec$unit,model=model,current=tail(d$value,1),estimate=estimate,
        lower95=bounds[1],lower80=bounds[2],upper80=bounds[3],upper95=bounds[4],
        change_pct=100*(estimate/tail(d$value,1)-1),calibration_n=length(residual),evidence=evidence,
        gap_months=gap,review_date=if(valid_review)review$review_date else as.Date(NA))
    }
  }
  if(length(out))do.call(rbind,out) else data.frame()
}
