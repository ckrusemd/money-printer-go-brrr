# Pure transformations: no I/O, network access or model selection.
research_series <- function(data,id,as_of=as.Date("9999-12-31")) {
  x <- data$observations[data$observations$id==id & data$observations$date<=as_of,]
  x[order(x$date),]
}

research_asof <- function(dates, source_dates, values) {
  if(!length(source_dates)) return(rep(NA_real_,length(dates)))
  order <- order(source_dates);source_dates<-as.Date(source_dates[order]);values<-values[order]
  if(anyDuplicated(source_dates)) stop("As-of join requires unique source dates")
  at <- findInterval(as.numeric(dates),as.numeric(source_dates))
  out <- rep(NA_real_,length(at));out[at>0L]<-values[at[at>0L]];out
}

research_returns <- function(date,value,lag=1L) {
  if(anyDuplicated(date)||is.unsorted(date)) stop("Returns require unique sorted observations")
  out <- rep(NA_real_,length(value))
  if(length(value)>lag) {
    current<-value[seq.int(lag+1L,length(value))];prior<-head(value,-lag)
    out[seq.int(lag+1L,length(value))]<-ifelse(current>0&prior>0,100*(current/prior-1),NA_real_)
  }
  out
}

research_quarter <- function(date) as.Date(lubridate::floor_date(date,"quarter"))
research_quarterly <- function(x,method=c("mean","last")) {
  method<-match.arg(method)
  if(!nrow(x)) return(data.frame(date=as.Date(character()),value=double()))
  q<-research_quarter(x$date)
  indices<-split(seq_len(nrow(x)),as.character(q))
  out<-do.call(rbind,lapply(indices,function(i) data.frame(date=research_period_end(q[i[1]],"quarterly"),
    value=if(method=="last") tail(x$value[i],1) else mean(x$value[i],na.rm=TRUE))))
  out[order(out$date),]
}

research_real_values <- function(data,id,basis=c("DKK","local"),base_date=NULL) {
  basis<-match.arg(basis);x<-research_series(data,id)
  if(!nrow(x)) return(x)
  currency<-x$currency[1];if(!nzchar(currency)) currency<-if(x$country[1]=="DK") "DKK" else "USD"
  amount<-x$value
  fx <- function(id) {s<-research_series(data,id);research_asof(x$date,s$date,s$value)}
  if(basis=="DKK" && currency!="DKK") {
    amount<-amount*fx("usd_dkk")
    if(currency=="EUR") amount<-amount*fx("eur_usd")
    if(currency=="JPY") amount<-amount/fx("usd_jpy")
    if(!currency %in% c("USD","EUR","JPY")) stop("Unsupported currency conversion: ",currency)
  }
  cpi_id<-if(basis=="DKK"||currency=="DKK") "dk_cpi" else "us_cpi"
  if(basis=="local"&&currency=="EUR")cpi_id<-"eur_cpi"
  if(basis=="local"&&currency=="JPY")cpi_id<-"jpy_cpi"
  cpi<-research_series(data,cpi_id)
  deflator<-research_asof(x$date,cpi$date,cpi$value)
  # Never extend a discontinued CPI indefinitely into current purchasing power.
  if(nrow(cpi))deflator[x$date>max(cpi$date)+100L]<-NA_real_
  valid<-which(is.finite(amount)&amount>0&is.finite(deflator)&deflator>0)
  x$nominal<-x$real<-rep(NA_real_,nrow(x))
  if(!length(valid)) return(x)
  at<-if(is.null(base_date)) valid[1] else {v<-valid[x$date[valid]>=as.Date(base_date)];if(length(v)) v[1] else tail(valid,1)}
  x$nominal<-100*amount/amount[at]
  x$real<-100*(amount/deflator)/(amount[at]/deflator[at])
  x$basis<-if(basis=="DKK") "DKK / Danish CPI" else paste(currency,"/ domestic CPI")
  x
}

research_summary <- function(data,ids) {
  rows<-lapply(ids,function(id) {
    x<-research_series(data,id);if(!nrow(x)) return(NULL)
    latest<-tail(x,1);frequency<-latest$frequency
    lag<-if(frequency=="monthly") 12L else if(frequency=="quarterly") 4L else 1L
    change<-tail(research_returns(x$date,x$value,lag),1)
    data.frame(Series=latest$label,Observation=latest$date,Value=latest$value,Unit=latest$unit,
      `Change (%)`=change,`Change window`=if(lag==12) "12 observations" else if(lag==4) "4 quarters" else "Previous observation",
      `Age (days)`=as.integer(book_date()-latest$date),check.names=FALSE)
  });do.call(rbind,rows)
}

research_growth <- function(data,ids) do.call(rbind,lapply(ids,function(id) {
  x<-research_series(data,id);if(nrow(x)<2L) return(NULL)
  n<-nrow(x);last<-tail(x$value,1);days<-as.numeric(tail(x$date,1)-x$date[1]);
  change<-function(days) {at<-which(x$date<=tail(x$date,1)-days);if(!length(at)) return(NA_real_);100*(last/x$value[tail(at,1)]-1)}
  ret<-diff(log(x$value));kind<-data$assets$kind[match(id,data$assets$id)]
  annual<-if(identical(kind,"crypto")) 365 else 252
  data.frame(id=id,Asset=x$label[1],First=x$date[1],Latest=tail(x$date,1),
    `1 week %`=change(7),`1 month %`=change(30),`3 months %`=change(91),`1 year %`=change(365),
    `5 year CAGR %`=if(is.finite(change(1826))) 100*((1+change(1826)/100)^(1/5)-1) else NA_real_,
    `Full history CAGR %`=if(days>365)100*((last/x$value[1])^(365.25/days)-1) else NA_real_,
    `Max drawdown %`=min(100*(x$value/cummax(x$value)-1)),
    `Annualized volatility %`=100*stats::sd(ret)*sqrt(annual),check.names=FALSE)
}))

research_correlations <- function(data,target,indicators,lags=0:8,min_n=40L,change=c("quarterly","yearly")) {
  change<-match.arg(change);step<-if(change=="quarterly")1L else 4L
  y<-research_quarterly(research_series(data,target),"last")
  if(!nrow(y)) return(data.frame())
  rows<-list()
  for(id in indicators) {
    x<-research_quarterly(research_series(data,id),"mean");if(!nrow(x)) next
    original<-research_series(data,id)
    # Join actual quarters first: an absent quarter must never shorten a lag.
    all_dates<-seq(research_quarter(min(c(x$date,y$date))),research_quarter(max(c(x$date,y$date))),by="quarter")
    all_dates<-research_period_end(all_dates,"quarterly")
    xv<-x$value[match(all_dates,x$date)];yv<-y$value[match(all_dates,y$date)]
    xx<-if(original$unit[1]=="percent") {
      v<-rep(NA_real_,length(xv));if(length(xv)>step)v[(step+1L):length(xv)]<-diff(xv,lag=step);v
    } else research_returns(all_dates,xv,step)
    yy<-research_returns(all_dates,yv,step)
    for(lag in lags) {
      predictor<-if(lag==0L) xx else c(rep(NA_real_,lag),head(xx,-lag))
      keep<-is.finite(predictor)&is.finite(yy);n<-sum(keep)
      if(n<min_n||stats::sd(predictor[keep])==0||stats::sd(yy[keep])==0) next
      test<-stats::cor.test(predictor[keep],yy[keep],method="pearson")
      rolling<-vapply(seq_along(all_dates),function(i) {
        if(i<min_n)return(NA_real_)
        at<-seq.int(i-min_n+1L,i)
        if(!all(keep[at])||stats::sd(predictor[at])==0||stats::sd(yy[at])==0)return(NA_real_)
        stats::cor(predictor[at],yy[at])
      },double(1))
      rolling<-rolling[is.finite(rolling)]
      rows[[length(rows)+1L]]<-data.frame(target=target,indicator=id,lag_quarters=lag,n=n,
        correlation=unname(test$estimate),p=test$p.value,
        rolling_min=if(length(rolling))min(rolling) else NA_real_,
        rolling_max=if(length(rolling))max(rolling) else NA_real_)
    }
  }
  if(!length(rows)) return(data.frame())
  out<-do.call(rbind,rows);out$q<-stats::p.adjust(out$p,method="BH");out[order(out$q,-abs(out$correlation)),]
}

research_joint_returns <- function(data,a,b) {
  x<-research_series(data,a);y<-research_series(data,b)
  dates<-intersect(as.character(x$date),as.character(y$date));dates<-as.Date(sort(dates))
  # Sample joint endpoints before differencing, so Monday/weekend intervals match.
  data.frame(date=dates,a=research_returns(dates,x$value[match(dates,x$date)]),
    b=research_returns(dates,y$value[match(dates,y$date)]))
}
