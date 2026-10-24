# Synthetic data for the offline CI presentation only; no provider substitution.
# Loaded solely by the staged notebook produced by pipeline_fixture.py.
dates<-research_period_end(seq(as.Date("2022-01-01"),by="month",length.out=36L),"monthly")
ids<-c("dk_build_counts_10000_3","dk_house_bis","dk_cpi","us_cpi","dk_employees",
  "us_payroll","sp500","c25","yield_10","bitcoin")
observations<-do.call(rbind,lapply(ids,function(id)research_rows(id,dates,
  if(id=="yield_10")seq(2,4,length.out=36) else seq(100,150,length.out=36),
  "monthly",if(id=="yield_10")"percent" else "index",paste("Synthetic",id))))
targets<-c("dk_build_counts_10000_3","sp500","c25","bitcoin")
forecasts<-do.call(rbind,lapply(targets,function(id)data.frame(id=id,
  origin=book_date(),last_observed=tail(dates,1),target_date=as.Date(NA),
  horizon=if(id==targets[1])c(3L,12L) else if(id=="bitcoin")c(7L,365L) else c(20L,252L),
  horizon_unit=if(id==targets[1])"months" else if(id=="bitcoin")"calendar days" else "trading sessions",
  model="benchmark",current=150,estimate=c(150,155),calibration_n=0L)))
ctx<-list(data=list(observations=observations,assets=research_assets()),forecasts=forecasts,review=NULL)
