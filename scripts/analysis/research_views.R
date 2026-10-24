source("scripts/analysis/research_data.R")
source("scripts/analysis/research_math.R")
source("scripts/analysis/research_models.R")

research_context <- function(forecasts=FALSE) {
  data<-research_data();result<-list(data=data,forecasts=NULL,review=NULL)
  file<-".cache/research-models/review.rds"
  if(file.exists(file))result$review<-readRDS(file)
  if(forecasts) {
    cache<-file.path(.book_runtime$snapshots,"research-forecasts.rds")
    key<-book_hash(list(signature=research_model_signature(),as_of=book_date(),
      data=book_hash(data$observations),review=if(is.list(result$review))book_hash(result$review) else NULL))
    old<-if(file.exists(cache))readRDS(cache) else NULL
    if(is.list(old)&&identical(old$key,key))result$forecasts<-old$value else {
      result$forecasts<-research_forecasts(data,result$review)
      book_save_rds(list(key=key,value=result$forecasts),cache)
    }
  }
  result
}

research_table <- function(x,caption=NULL) {
  if(is.null(x)||!nrow(x)) {IRdisplay::display_markdown("No observations or validated comparisons are available for this selection.");return(invisible(NULL))}
  for(name in names(x))if(is.numeric(x[[name]]))x[[name]]<-round(x[[name]],4)
  DT::datatable(x,rownames=FALSE,caption=caption,filter="top",
    options=list(scrollX=TRUE,pageLength=8,lengthMenu=c(8,20,50),dom="lftip"))
}

research_chart <- function(data,ids,title,transform=c("level","growth","index"),lag=NULL) {
  transform<-match.arg(transform);rows<-list()
  for(id in ids) {
    x<-research_series(data,id);if(!nrow(x))next
    value<-x$value
    if(transform=="growth")value<-research_returns(x$date,value,if(is.null(lag))if(x$frequency[1]=="quarterly")4L else 12L else lag)
    if(transform=="index")value<-100*value/value[which(is.finite(value)&value>0)[1]]
    rows[[length(rows)+1L]]<-data.frame(date=x$date,value=value,label=x$label,
      unit=if(transform=="level")x$unit else if(transform=="growth")"percent" else "index, first observation=100")
  }
  if(!length(rows))return(ggplot2::ggplot()+ggplot2::theme_void()+ggplot2::labs(title=title,subtitle="Source unavailable"))
  d<-do.call(rbind,rows)
  p<-ggplot2::ggplot(d,ggplot2::aes(date,value,color=label))+ggplot2::geom_line(linewidth=.6,na.rm=TRUE)+
    theme_money_printer_go_brrr(11)+ggplot2::labs(title=title,x=NULL,y=NULL,color=NULL,
      caption="Native observations; hover for dates and values. Legend controls select series.")
  if(length(unique(d$unit))>1)p<-p+ggplot2::facet_wrap(~unit,scales="free_y")
  plotly::layout(plotly::ggplotly(p,tooltip=c("x","y","colour")),
    xaxis=list(rangeslider=list(visible=TRUE),rangeselector=list(buttons=list(
      list(count=1,label="1y",step="year",stepmode="backward"),list(count=5,label="5y",step="year",stepmode="backward"),list(step="all",label="All")))))
}

research_value_chart <- function(data,ids,title="Historical growth and purchasing power") {
  ids<-intersect(ids,unique(data$observations$id));if(!length(ids))return(NULL)
  first<-max(vapply(ids,function(id)as.numeric(min(research_series(data,id)$date)),double(1)))
  options<-list(nominal="Nominal, native currency",DKK="Real DKK / Danish CPI",local="Real native currency / domestic CPI")
  plot<-plotly::plot_ly();trace_modes<-character()
  for(mode in names(options)) for(id in ids) {
    x<-if(mode=="nominal")research_series(data,id) else research_real_values(data,id,mode,as.Date(first,origin="1970-01-01"))
    x<-x[x$date>=as.Date(first,origin="1970-01-01"),]
    if(!nrow(x))next
    value<-if(mode=="nominal")100*x$value/x$value[1] else x$real
    # Display sampling only: all return and model calculations retain native data.
    keep<-seq(1,nrow(x),by=max(1L,floor(nrow(x)/1800L)));keep<-union(keep,nrow(x))
    plot<-plotly::add_lines(plot,x=x$date[keep],y=value[keep],name=x$label[1],visible=mode=="nominal",
      hovertemplate="%{x}<br>%{y:.2f}<extra>%{fullData.name}</extra>")
    trace_modes<-c(trace_modes,mode)
  }
  buttons<-lapply(names(options),function(mode)list(method="update",label=options[[mode]],
    args=list(list(visible=trace_modes==mode),list(yaxis=list(title=options[[mode]])))))
  plotly::layout(plot,title=list(text=title,font=list(size=16)),yaxis=list(title="Index, selected start=100"),
    xaxis=list(rangeslider=list(visible=TRUE)),updatemenus=list(list(buttons=buttons,x=0,y=1.2)),
    margin=list(t=95),legend=list(orientation="h",y=-.3))
}

research_forecast_table <- function(ctx,ids) {
  x<-ctx$forecasts;if(is.null(x)||!nrow(x))return(research_table(data.frame()))
  x<-x[x$id%in%ids,]
  research_table(x[,c("id","origin","last_observed","target_date","horizon","horizon_unit","model",
    "current","estimate","change_pct","lower80","upper80","lower95","upper95","calibration_n","evidence","gap_months")],
    "Nominal native-unit forecasts. Asset horizons start at the latest completed close; construction horizons start at the edition month. Session-based targets have no invented holiday-calendar date. Missing bounds mean insufficient calibration history.")
}

research_forecast_chart <- function(ctx,id) {
  f<-ctx$forecasts
  if(is.null(f)||!nrow(f))return(NULL)
  f<-f[f$id==id,];if(!nrow(f))return(NULL)
  spec<-Filter(function(s)s$id==id,research_targets(ctx$data))[[1]]
  d<-research_target_data(ctx$data,spec);d<-utils::tail(d,if(spec$monthly)60L else 252L)
  if(!nrow(d))return(NULL)
  # Use explicit observation steps for exchange sessions, never synthetic dates.
  x<-seq_len(nrow(d))-nrow(d)
  lead<-f$horizon+if(spec$monthly)f$gap_months else 0L
  p<-plotly::plot_ly()
  p<-plotly::add_lines(p,x=x,y=d$value,name="Observed",text=as.character(d$date),
    hovertemplate="%{text}<br>%{y:.2f}<extra>Observed</extra>")
  for(level in c("95","80")) {
    lo<-f[[paste0("lower",level)]];hi<-f[[paste0("upper",level)]]
    ok<-is.finite(lo)&is.finite(hi)
    if(!any(ok))next
    p<-plotly::add_trace(p,x=c(lead[ok],rev(lead[ok])),y=c(lo[ok],rev(hi[ok])),
      type="scatter",mode="lines",fill="toself",line=list(color="transparent"),
      fillcolor=if(level=="95")"rgba(35,97,141,0.12)" else "rgba(35,97,141,0.22)",
      name=paste0(level,"% empirical range"),hoverinfo="skip")
  }
  p<-plotly::add_trace(p,x=c(0,lead),y=c(tail(d$value,1),f$estimate),type="scatter",mode="lines+markers",
    name="Published forecast",text=c(paste("Last observed",tail(d$date,1)),paste(f$model,"·",f$horizon,f$horizon_unit)),
    hovertemplate="%{text}<br>%{y:.2f}<extra>Forecast</extra>")
  plotly::layout(p,title=list(text=paste(id,"· observed history and forecast"),font=list(size=16)),
    xaxis=list(title=paste(spec$unit,"relative to latest observation; 0 =",tail(d$date,1))),
    yaxis=list(title="Nominal native units"),legend=list(orientation="h",y=-.3),margin=list(b=100))
}

research_score_table <- function(ctx,ids) {
  r<-ctx$review
  if(!is.list(r)||!identical(r$signature,research_model_signature()))return(research_table(data.frame()))
  research_table(r$scores[r$scores$id%in%ids,],paste("Historical review:",r$review_date,
    "· MASE uses training-only naive scale; relative MAE compares the same test origins."))
}

research_curve <- function(data) {
  maturity<-c(.0833,.25,.5,1,2,5,10,20,30)
  ids<-paste0("yield_",c("1mo","3mo","6mo","1","2","5","10","20","30"))
  dates<-c(book_date(),book_date()-30,book_date()-365);rows<-list()
  for(date in as.character(dates)) for(i in seq_along(ids)) {
    x<-research_series(data,ids[i],as.Date(date));if(!nrow(x))next
    last<-tail(x,1);rows[[length(rows)+1L]]<-data.frame(maturity=maturity[i],yield=last$value,
      curve=date,observed=last$date)
  }
  d<-do.call(rbind,rows)
  plotly::ggplotly(ggplot2::ggplot(d,ggplot2::aes(maturity,yield,color=curve,text=paste("Observed",observed)))+
    ggplot2::geom_line()+ggplot2::geom_point()+theme_money_printer_go_brrr(11)+
    ggplot2::labs(title="US Treasury curves: current, one month and one year earlier",x="Maturity (years)",y="Yield (%)",color="As of"),tooltip=c("x","y","text","colour"))
}

research_spreads <- function(data) {
  long<-research_series(data,"yield_10");short<-research_series(data,"yield_2");months<-research_series(data,"yield_3mo")
  d<-merge(long[,c("date","value")],short[,c("date","value")],by="date",suffixes=c("_10","_2"))
  d<-merge(d,months[,c("date","value")],by="date");names(d)[4]<-"value_3mo"
  rows<-rbind(data.frame(date=d$date,value=d$value_10-d$value_2,label="10y minus 2y"),
    data.frame(date=d$date,value=d$value_10-d$value_3mo,label="10y minus 3m"))
  plotly::ggplotly(ggplot2::ggplot(rows,ggplot2::aes(date,value,color=label))+
    ggplot2::geom_hline(yintercept=0,linetype=2)+ggplot2::geom_line()+theme_money_printer_go_brrr(11)+
    ggplot2::labs(title="Treasury slope: negative values indicate inversion",x=NULL,y="Percentage points",color=NULL))
}

research_mortgages <- function() {
  url<-book_finansdanmark_url("https://finansdanmark.dk/tal-og-data/boligstatistik/obligationsrenter/")
  x<-book_workbook(url,sheet="Data",startRow=1)
  research_table(utils::tail(x,20),"Finans Danmark weekly mortgage-bond yields; these are not a sovereign yield curve.")
}

research_overview <- function(ctx) {
  ids<-c("dk_build_counts_10000_3","dk_house_bis","us_house","dk_cpi","us_cpi","dk_employees",
    "us_payroll","yield_10","policy_us","sp500","c25","bitcoin","ethereum","solana")
  research_table(research_summary(ctx$data,ids),paste("Research edition",book_date(),"· observation dates and ages differ by provider"))
}

research_release_table <- function(ctx) {
  d<-ctx$data$observations
  rows<-lapply(split(d,d$id),function(x) {
    last<-tail(x,1);data.frame(Series=last$label,Observation=last$date,Age_days=as.integer(book_date()-last$date),
      Frequency=last$frequency,Units=last$unit,Source=last$source,Historical_basis=last$revision)
  })
  research_table(do.call(rbind,rows),"Observation period is separate from retrieval time. Historical release lags are estimates unless recorded ALFRED dates are available. Discontinued CPI is not extended beyond 100 days after its last period.")
}

research_relative_risk <- function(ctx,ids,benchmark="sp500") {
  rows<-lapply(ids,function(id) {
    d<-research_joint_returns(ctx$data,id,benchmark);d<-d[is.finite(d$a)&is.finite(d$b),]
    if(nrow(d)<60)return(NULL)
    do.call(rbind,lapply(c(30L,90L,365L),function(n) {
      x<-tail(d,n);data.frame(asset=id,benchmark=benchmark,matched_intervals=nrow(x),
        correlation=stats::cor(x$a,x$b),first=x$date[1],last=tail(x$date,1))
    }))
  });research_table(do.call(rbind,rows),"Returns use the same observed interval endpoints; crypto weekend moves are accumulated to the equity endpoint.")
}

research_cor_table <- function(ctx,target) {
  indicators<-c("us_payroll","us_unemployment","us_income","us_cpi","us_permits","us_starts","mortgage_us",
    "dk_employees","dk_rates_LPCT","dk_cpi","dk_build_counts_10000_1","dk_build_counts_10000_2","yield_10","policy_us","us_money")
  q<-research_correlations(ctx$data,target,indicators)
  y<-research_correlations(ctx$data,target,indicators,change="yearly")
  if(nrow(q))q$change_basis<-"Quarterly changes"
  if(nrow(y))y$change_basis<-"Annual changes"
  research_table(rbind(q,y),"Positive lag means the indicator precedes house-price growth. BH q-values are exploratory; serial dependence and overlapping annual changes limit causal interpretation.")
}
