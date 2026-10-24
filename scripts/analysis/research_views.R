source("scripts/analysis/research_data.R")
source("scripts/analysis/research_math.R")
source("scripts/analysis/research_models.R")

research_validate_data <- function(data) {
  for(spec in research_targets(data)) {
    if(!spec$monthly&&spec$unit!="calendar days")next
    d<-research_target_data(data,spec);if(!nrow(d))next
    expected<-if(spec$monthly)research_period_end(seq(
      lubridate::floor_date(min(d$date),"month"),lubridate::floor_date(max(d$date),"month"),by="month"),"monthly") else
      seq(min(d$date),max(d$date),by="day")
    if(length(d$date)!=length(expected)||any(as.numeric(d$date)!=as.numeric(expected)))
      stop("Missing native model periods; no synthetic fill: ",spec$id)
  }
  area<-data$observations[grepl("^dk_build_area_(120|130|140)_3$",data$observations$id),]
  if(nrow(area)&&any(table(area$date)!=3L))stop("Incomplete residential floor-area components; refusing partial totals")
  invisible(TRUE)
}

research_context <- function(forecasts=FALSE) {
  data<-research_data();research_validate_data(data)
  result<-list(data=data,forecasts=NULL,review=NULL)
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
    evidence<-Sys.getenv("BOOK_RESULTS_DIR","")
    if(nzchar(evidence)) {
      book_save_rds(result$forecasts,file.path(evidence,"research-forecasts.rds"))
      if(is.list(result$review))book_save_rds(result$review,file.path(evidence,"research-review.rds"))
    }
  }
  result
}

research_table <- function(x,caption=NULL) {
  if(is.null(x)||!nrow(x)) {IRdisplay::display_markdown("No observations or validated comparisons are available for this selection.");return(invisible(NULL))}
  for(name in names(x))if(is.numeric(x[[name]]))x[[name]]<-if(name%in%c("p","q"))
    format.pval(x[[name]],digits=3,eps=.0001) else round(x[[name]],4)
  DT::datatable(x,rownames=FALSE,caption=caption,filter="top",
    options=list(scrollX=TRUE,pageLength=8,lengthMenu=c(8,20,50),dom="lftip"))
}

research_plot_label <- function(id,label) {
  labels<-c(dk_cpi="Denmark CPI",us_cpi="US CPI",us_cpi_sa="US CPI, SA",
    us_payroll="US payroll jobs",us_employed="US employed people",dk_employees="Danish employees",
    us_unemployment="US unemployment",dk_rates_LPCT="Danish unemployment",
    us_participation="US participation",dk_rates_EFK="Danish participation",dk_rates_BFK="Danish employment rate",
    dk_house_houses="Detached / terraced houses",dk_house_apartments="Owner-occupied flats",dk_house_holiday="Holiday homes",
    us_house="US Case-Shiller",dk_house_bis="Denmark BIS",us_house_bis="US BIS",
    dk_completed_area="Completed residential floor area",dk_labour_BESTOT="Danish employed people")
  if(id%in%names(labels))return(unname(labels[id]))
  if(grepl("^dk_build",id)) {
    parts<-strsplit(id,"_")[[1]];type<-parts[length(parts)-1L];phase<-tail(parts,1)
    types<-c("10000"="all dwellings","10300"="one-family","10400"="multi-dwelling",
      "120"="detached houses","130"="terraced / linked houses","140"="apartment buildings")
    phases<-c("1"="Permits","2"="Starts","3"="Completions","4"="In progress")
    if(type%in%names(types)&&phase%in%names(phases))return(paste(phases[phase],types[type],sep=" · "))
  }
  label
}

research_date_plot <- function(plot) {
  # ggplotly serializes ggplot Date scales as linear days since 1970. Convert
  # both traces and axes before adding Plotly's calendar-aware controls.
  for(i in seq_along(plot$x$data)) {
    x<-plot$x$data[[i]]$x
    if(is.numeric(x))plot$x$data[[i]]$x<-as.character(as.Date(x,origin="1970-01-01"))
  }
  for(name in grep("^xaxis[0-9]*$",names(plot$x$layout),value=TRUE)) {
    axis<-plot$x$layout[[name]]
    if(is.numeric(axis$range))axis$range<-as.character(as.Date(axis$range,origin="1970-01-01"))
    axis$type<-"date";axis$tickmode<-"auto";axis$hoverformat<-"%d %b %Y"
    axis$tickvals<-axis$ticktext<-axis$categoryarray<-axis$categoryorder<-NULL
    plot$x$layout[[name]]<-axis
  }
  plot
}

research_chart <- function(data,ids,title,transform=c("level","growth","index"),lag=NULL) {
  transform<-match.arg(transform);rows<-list()
  for(id in ids) {
    x<-research_series(data,id);if(!nrow(x))next
    value<-x$value
    if(transform=="growth")value<-research_returns(x$date,value,if(is.null(lag))if(x$frequency[1]=="quarterly")4L else 12L else lag)
    if(transform=="index")value<-100*value/value[which(is.finite(value)&value>0)[1]]
    rows[[length(rows)+1L]]<-data.frame(date=x$date,value=value,label=research_plot_label(id,x$label[1]),
      unit=if(transform=="level")x$unit else if(transform=="growth")"percent" else "index, first observation=100")
  }
  if(!length(rows))return(ggplot2::ggplot()+ggplot2::theme_void()+ggplot2::labs(title=title,subtitle="Source unavailable"))
  d<-do.call(rbind,rows)
  p<-ggplot2::ggplot(d,ggplot2::aes(date,value,color=label))+ggplot2::geom_line(linewidth=.6,na.rm=TRUE)+
    theme_money_printer_go_brrr(11)+ggplot2::labs(title=title,x=NULL,y=NULL,color=NULL,
      caption="Native observations; hover for dates and values. Legend controls select series.")
  if(length(unique(d$unit))>1)p<-p+ggplot2::facet_wrap(~unit,scales="free_y")
  plotly::layout(research_date_plot(plotly::ggplotly(p,tooltip=c("x","y","colour"))),
    legend=list(orientation="h",x=0,y=-.3,yanchor="top",font=list(size=10)),
    margin=list(b=150,r=20),
    xaxis=list(range=as.character(c(max(min(d$date),book_date()-3653L),book_date())),
      rangeslider=list(visible=TRUE,thickness=.12),rangeselector=list(buttons=list(
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
  x$Series<-vapply(x$id,function(id){s<-research_series(ctx$data,id);research_plot_label(id,if(nrow(s))s$label[1] else id)},character(1))
  x$Units<-vapply(x$id,research_forecast_unit,character(1))
  view<-x[,c("Series","Units","origin","last_observed","target_date","horizon","horizon_unit","model",
    "current","estimate","change_pct","lower80","upper80","lower95","upper95","calibration_n","evidence","gap_months")]
  names(view)<-c("Series","Units","Edition","Last observed","Target date","Horizon","Horizon unit","Model",
    "Observed value","Forecast","Change %","80% lower","80% upper","95% lower","95% upper","Calibration origins","Evidence","Reporting gap (months)")
  research_table(view,
    "Nominal native-unit forecasts. Asset horizons start at the latest completed close; construction horizons start at the edition month. Session-based targets have no invented holiday-calendar date. Missing bounds mean insufficient calibration history.")
}

research_forecast_unit <- function(id) {
  if(id=="dk_completed_area")return("m²")
  if(startsWith(id,"dk_build"))return("dwellings")
  if(id%in%c("bitcoin","ethereum","solana"))return("USD/token")
  if(id=="world")return("USD/ETF share")
  "index points"
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
  s<-research_series(ctx$data,id);label<-research_plot_label(id,if(nrow(s))s$label[1] else id)
  plotly::layout(p,title=list(text=paste(label,"· observed history and forecast"),font=list(size=16)),
    xaxis=list(title=paste(spec$unit,"relative to latest observation; 0 =",tail(d$date,1))),
    yaxis=list(title=research_forecast_unit(id)),legend=list(orientation="h",y=-.3),margin=list(b=100))
}

research_score_table <- function(ctx,ids) {
  r<-ctx$review
  if(!is.list(r)||!identical(r$signature,research_model_signature()))return(research_table(data.frame()))
  x<-r$scores[r$scores$id%in%ids,]
  if(nrow(x))x$id<-vapply(x$id,function(id){s<-research_series(ctx$data,id);research_plot_label(id,if(nrow(s))s$label[1] else id)},character(1))
  research_table(x,paste("Historical review:",r$review_date,
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
  research_date_plot(plotly::ggplotly(ggplot2::ggplot(rows,ggplot2::aes(date,value,color=label))+
    ggplot2::geom_hline(yintercept=0,linetype=2)+ggplot2::geom_line()+theme_money_printer_go_brrr(11)+
    ggplot2::labs(title="Treasury slope: negative values indicate inversion",x=NULL,y="Percentage points",color=NULL)))
}

research_parse_mortgages <- function(x) {
  if(ncol(x)<4L)stop("Unexpected mortgage workbook layout")
  number<-function(i)suppressWarnings(as.numeric(gsub(",",".",as.character(x[[i]]),fixed=TRUE)))
  year<-number(1);week<-number(2)
  keep<-is.finite(year)&year>=1900&year<=2100&is.finite(week)&week>=1&week<=53
  year<-as.integer(year[keep]);week<-as.integer(week[keep])
  date<-as.Date(lubridate::floor_date(as.Date(sprintf("%04d-01-04",year)),"week",week_start=1))+7L*(week-1L)
  d<-data.frame(Week_start=date,Year=year,Week=week,Short_DKK=number(3)[keep],Long_DKK=number(4)[keep],
    Short_EUR=if(ncol(x)>=5L)number(5)[keep] else NA_real_,
    Note=if(ncol(x)>=6L)as.character(x[[6]])[keep] else "")
  if(anyDuplicated(d$Week_start))stop("Duplicate mortgage weeks")
  d<-d[d$Week_start<=book_date(),];d[order(d$Week_start,decreasing=TRUE),]
}

research_mortgage_data <- function() {
  url<-book_finansdanmark_url("https://finansdanmark.dk/tal-og-data/boligstatistik/obligationsrenter/")
  research_parse_mortgages(book_workbook(url,sheet="Data",startRow=1,detectDates=TRUE))
}

research_mortgages <- function() {
  research_table(utils::head(research_mortgage_data(),20),
    "Latest Finans Danmark mortgage-bond yields (%), sorted newest first. Week_start is the ISO-week Monday, not a daily quote. Source notes retain carried-forward EUR observations.")
}

research_mortgage_chart <- function() {
  d<-research_mortgage_data();rows<-do.call(rbind,lapply(c("Short_DKK","Long_DKK","Short_EUR"),function(id)
    data.frame(date=d$Week_start,value=d[[id]],label=gsub("_"," ",id))))
  plotly::layout(research_date_plot(plotly::ggplotly(ggplot2::ggplot(rows,ggplot2::aes(date,value,color=label))+
    ggplot2::geom_line(na.rm=TRUE)+theme_money_printer_go_brrr(11)+
    ggplot2::labs(title="Weekly Danish mortgage-bond yields",x=NULL,y="Yield (%)",color=NULL))),
    legend=list(orientation="h",x=0,y=-.25),margin=list(b=120),
    xaxis=list(range=as.character(c(book_date()-3653L,book_date())),rangeslider=list(visible=TRUE)))
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

research_complete_quarters <- function(data) {
  # Correlations compare complete periods: a July house-price observation must
  # not be labelled September and compared with August/September indicators.
  rows<-split(seq_len(nrow(data$observations)),paste(data$observations$id,
    research_quarter(data$observations$date),sep="|"))
  keep<-unlist(lapply(rows,function(at) {
    x<-data$observations[at,];q<-research_quarter(x$date[1]);end<-research_period_end(q,"quarterly")
    if(end>book_date())return(integer())
    freq<-x$frequency[1]
    if(freq=="monthly"&&length(unique(format(x$date,"%Y-%m")))!=3L)return(integer())
    if(freq%in%c("daily","weekly")&&(min(x$date)>q+7L||max(x$date)<end-7L))return(integer())
    at
  }),use.names=FALSE)
  data$observations<-data$observations[sort(keep),];data
}

research_cor_table <- function(ctx,target) {
  indicators<-c("us_payroll","us_unemployment","us_income","us_cpi","us_permits","us_starts","mortgage_us",
    "dk_employees","dk_labour_BESTOT","dk_rates_LPCT","dk_cpi","dk_build_counts_10000_1","dk_build_counts_10000_2","yield_10","policy_us","us_money")
  data<-research_complete_quarters(ctx$data)
  q<-research_correlations(data,target,indicators)
  y<-research_correlations(data,target,indicators,change="yearly")
  if(nrow(q))q$change_basis<-"Quarterly changes"
  if(nrow(y))y$change_basis<-"Annual changes"
  evidence<-Sys.getenv("BOOK_RESULTS_DIR","")
  if(nzchar(evidence))book_save_rds(list(quarterly=q,yearly=y),
    file.path(evidence,paste0("research-correlations-",target,".rds")))
  research_table(rbind(q,y),"Positive lag means the indicator precedes house-price growth. BH q-values are exploratory; serial dependence and overlapping annual changes limit causal interpretation.")
}
