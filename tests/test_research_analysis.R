# Deterministic tests of the economic definitions and chronological model gates.
Sys.setenv(BOOK_AS_OF="2026-10-24")
source("scripts/book_runtime.R")
source("scripts/analysis/research_data.R")
source("scripts/analysis/research_math.R")
source("scripts/analysis/research_models.R")
close_to<-function(a,b)stopifnot(isTRUE(all.equal(as.numeric(a),as.numeric(b),tolerance=1e-8)))
days<-as.Date("2020-01-01")+0:3
close_to(research_asof(days,days[c(2,4)],c(10,20)),c(NA,10,10,20))
stopifnot(inherits(try(research_asof(days,days[c(1,1)],1:2),silent=TRUE),"try-error"))
stopifnot(inherits(try(research_returns(rev(days),1:4),silent=TRUE),"try-error"))
close_to(research_returns(days,c(100,110,0,120)),c(NA,10,NA,NA))

make<-function(id,value,currency="",date=days)research_rows(id,date,value,"daily","price",id,currency=currency)
d<-list(observations=rbind(make("stock",c(100,110,120,130),"USD"),
  make("usd_dkk",rep(6,4)),make("dk_cpi",c(100,100,120,120)),make("us_cpi",rep(100,4))),assets=research_assets())
close_to(research_real_values(d,"stock","DKK")$real,c(100,110,100,130/1.2))
close_to(research_real_values(d,"stock","local")$real,c(100,110,120,130))
eur<-make("euro",1:4,"EUR");d$observations<-rbind(d$observations,eur,make("eur_usd",rep(2,4)))
stopifnot(all(is.na(research_real_values(d,"euro","local")$real)))
close_to(research_real_values(d,"euro","DKK")$real,c(100,200,250,400/1.2))
# Missing weekends are accumulated over matching endpoints, not matched after returns.
d$observations<-rbind(make("equity",c(100,120),date=days[c(1,4)]),make("crypto",c(100,101,110,120)))
joint<-research_joint_returns(d,"equity","crypto")
stopifnot(nrow(joint)==2);close_to(joint$a,joint$b)

# A missing quarter breaks the growth calculation on both sides of the gap.
dates<-research_period_end(seq(as.Date("2000-01-01"),by="quarter",length.out=90),"quarterly")
set.seed(1);values<-100*cumprod(1+stats::rnorm(90,0.01,.03))
d$observations<-rbind(make("house",values,date=dates),make("indicator",values,date=dates))
full<-research_correlations(d,"house","indicator",lags=0,min_n=40)
close_to(full$correlation,1);stopifnot(full$n==89)
d$observations<-d$observations[!(d$observations$id=="indicator"&d$observations$date==dates[50]),]
gap<-research_correlations(d,"house","indicator",lags=0,min_n=40)
stopifnot(gap$n==87)

y<-log(seq_len(300)+100);x<-research_features(exp(y))
train<-research_training(y,x,i=290,h=20,window=100,differences=TRUE)
stopifnot(all(train$rows+20<=290),all(train$rows>=190))
close_to(train$y,y[train$rows+20]-y[train$rows])
# Future values cannot change the predictors or targets available at an origin.
future<-y;future[291:300]<-100
again<-research_training(future,research_features(exp(future)),290,20,100,TRUE)
stopifnot(identical(train,again))

records<-data.frame(id="fixture",origin=as.Date("2000-01-01")+30*0:59,
 target_date=as.Date("2000-01-01")+30*0:59+7,horizon=7L,model="benchmark",actual=100,
 estimate=110,scale=2,revision="Historical closing observations")
better<-records;better$model<-"random_forest";better$estimate<-108
scores<-research_model_scores(rbind(records,better))
stopifnot(scores$eligible[scores$model=="random_forest"])
close_to(scores$MASE[scores$model=="random_forest"],4)
small<-research_model_scores(rbind(head(records,29),head(better,29)))
stopifnot(!small$eligible[small$model=="random_forest"])
weak<-better;weak$estimate<-109.9
stopifnot(!research_model_scores(rbind(records,weak))$eligible[2])
perfect<-records;perfect$estimate<-perfect$actual;perfect$scale<-0
z<-research_model_scores(perfect);stopifnot(z$eligible,is.na(z$MASE),is.na(z$relative_MAE))
# Before 30 matured errors, historical calibration remains visibly absent.
small<-research_model_scores(head(records,30));stopifnot(is.na(small$coverage80))
stopifnot(as.character(research_period_end(as.Date("2024-02-01"),"monthly"))=="2024-02-29")
source("scripts/analysis/research_views.R")
d<-list(observations=make("bitcoin",1:3,"USD",date=days[c(1,2,4)]),assets=research_assets())
stopifnot(inherits(try(research_validate_data(d),silent=TRUE),"try-error"))
d$observations<-make("bitcoin",1:4,"USD",date=days)
stopifnot(research_validate_data(d))
dates<-research_period_end(seq(as.Date("2026-01-01"),by="month",length.out=7),"monthly")
d$observations<-research_rows("house",dates,1:7,"monthly","index","house")
complete<-research_complete_quarters(d)$observations
stopifnot(nrow(complete)==6L,max(complete$date)==as.Date("2026-06-30"))
d$observations<-d$observations[-2,]
stopifnot(nrow(research_complete_quarters(d)$observations)==3L)
x<-data.frame(a=c("År","1997","2026"),b=c("Uge","36","42"),
 c=c("Kort rente","3.99","2.82"),d=c("Lang rente","7.59","4.53"),
 e=c("Kort euro rente",NA,"2.68"),f=c(NA,NA,"EUR carried from previous week"))
m<-research_parse_mortgages(x)
stopifnot(m$Year[1]==2026L,m$Week_start[1]==as.Date("2026-10-12"),m$Short_DKK[1]==2.82,
 m$Note[1]=="EUR carried from previous week")
p<-research_date_plot(plotly::ggplotly(ggplot2::ggplot(data.frame(date=days,value=1:4),
  ggplot2::aes(date,value))+ggplot2::geom_line()))
stopifnot(p$x$layout$xaxis$type=="date",identical(p$x$data[[1]]$x,as.character(days)))
definitions<-parse("scripts/analysis/market_notebooks.R")
eval(Filter(function(x)is.call(x)&&identical(x[[1L]],as.name("<-"))&&
 identical(x[[2L]],as.name("book_cpi_base")),definitions)[[1]])
close_to(book_cpi_base(as.Date(c("2015-01-31","2015-02-28")),c(80,88)),c(100,110))
close_to(book_cpi_base(as.Date(c("2015-01-01","2015-02-01")),c(80,88)),c(100,110))
cat("Research definitions, currency conversion, calendar alignment and model gates passed\n")
