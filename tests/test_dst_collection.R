# Offline collection boundary: no database handle, credentials or writes.
source("scripts/analysis/dst_collection.R")
transport <- function(endpoint,p) {
  if(endpoint=="tableinfo") return(list(id="PRIS114",text="Prices",unit="Indeks",updated="2026-01-01",
    variables=list(
      list(id="VAREGR",text="varegruppe",time=FALSE,elimination=FALSE,values=list(list(id="000005",text="00 Nettoprisindeks i alt"))),
      list(id="ENHED",text="enhed",time=FALSE,elimination=FALSE,values=list(list(id="100",text="Indeks"))),
      list(id="Tid",text="tid",time=TRUE,elimination=FALSE,values=list(list(id="2024M01",text="2024M01"))))))
  dimension <- function(code) list(category=list(index=stats::setNames(list(0L),code),label=stats::setNames(list(code),code)))
  list(dataset=list(dimension=list(VAREGR=dimension("000005"),ENHED=dimension("100"),Tid=dimension("2024M01"),
    id=list("VAREGR","ENHED","Tid"),size=list(1L,1L,1L),role=list(time=list("Tid"))),value=list(120.5)))
}
cfg <- list(table="PRIS114",query=list(VAREGR="000005",ENHED="100",Tid="*"),series_cols=NULL)
x <- fetch_dst_table(cfg,transport=transport)
stopifnot(identical(names(x),c("series","date","value")),x$series=="PRIS114",
  x$date==as.Date("2024-01-01"),x$value==120.5,length(attr(x,"canonical_series_id"))==1L)
cfg$series_cols <- c("VAREGR","ENHED")
y <- fetch_dst_table(cfg,transport=transport)
stopifnot(y$series=="PRIS114_000005_00_Nettoprisindeks_i_alt_100_Indeks")
cat("DST collection adapter preserves date, value and cleaned external aliases without database writes\n")
