# Public observations and definitions used by the seven-theme research book.
# Source this after book_runtime.R; no requests occur until research_data().
research_assets <- function() data.frame(
  id=c("sp500","nasdaq","dow","russell","c25","europe","japan","world","bitcoin","ethereum","solana","gold"),
  symbol=c("^GSPC","^IXIC","^DJI","^RUT","^OMXC25","^STOXX50E","^N225","ACWI","BTC-USD","ETH-USD","SOL-USD","GC=F"),
  label=c("S&P 500","Nasdaq Composite","Dow Jones","Russell 2000","OMX C25","Euro Stoxx 50","Nikkei 225","World: ACWI ETF price proxy","Bitcoin","Ethereum","Solana","Gold futures"),
  currency=c("USD","USD","USD","USD","DKK","EUR","JPY","USD","USD","USD","USD","USD"),
  kind=c(rep("equity",8),rep("crypto",3),"commodity"), stringsAsFactors=FALSE)

research_fred_registry <- function() {
  rows <- list(
    c("us_cpi","CPIAUCNS","US consumer CPI","monthly","index","US","45"),
    c("us_cpi_sa","CPIAUCSL","US consumer CPI, seasonally adjusted","monthly","index","US","45"),
    c("eur_cpi","CP0000EZ19M086NEST","Euro-area HICP, all items","monthly","index","EU","45"),
    c("us_house","CSUSHPISA","US Case-Shiller national residential prices, SA","monthly","index","US","75"),
    c("dk_house_bis","QDKN628BIS","Danish national residential prices: BIS","quarterly","index","DK","100"),
    c("us_house_bis","QUSN628BIS","US national residential prices: BIS","quarterly","index","US","100"),
    c("us_payroll","PAYEMS","US nonfarm payroll jobs, SA","monthly","thousand jobs","US","10"),
    c("us_employed","CE16OV","US household employment, SA","monthly","thousand people","US","10"),
    c("us_unemployment","UNRATE","US unemployment rate, age 16+, SA","monthly","percent","US","10"),
    c("us_participation","CIVPART","US participation rate, age 16+, SA","monthly","percent","US","10"),
    c("us_claims","ICSA","US initial unemployment claims, SA","weekly","claims","US","7"),
    c("us_wage","CES0500000003","US private-sector average hourly earnings","monthly","USD/hour","US","10"),
    c("us_income","DSPIC96","US real disposable personal income","monthly","real USD","US","45"),
    c("us_permits","PERMIT","US housing permits, annualized, SA","monthly","thousand dwellings/year","US","30"),
    c("us_starts","HOUST","US housing starts, annualized, SA","monthly","thousand dwellings/year","US","30"),
    c("us_money","M2SL","US M2, SA","monthly","billion USD","US","35"),
    c("usd_dkk","DEXDNUS","DKK per USD","daily","DKK/USD","FX","1"),
    c("eur_usd","DEXUSEU","USD per EUR","daily","USD/EUR","FX","1"),
    c("usd_jpy","DEXJPUS","JPY per USD","daily","JPY/USD","FX","1"),
    c("policy_us","DFF","Federal funds effective rate","daily","percent","US","1"),
    c("real10","DFII10","US 10-year TIPS real yield","daily","percent","US","1"),
    c("breakeven10","T10YIE","US 10-year inflation compensation","daily","percent","US","1"),
    c("mortgage_us","MORTGAGE30US","US 30-year mortgage rate","weekly","percent","US","1"))
  terms <- c("1MO","3MO","6MO","1","2","5","10","20","30")
  for(t in terms) rows[[length(rows)+1L]] <- c(paste0("yield_",tolower(t)),paste0("DGS",t),paste("US Treasury",t),"daily","percent","US","1")
  x <- as.data.frame(do.call(rbind,rows),stringsAsFactors=FALSE)
  names(x) <- c("id","source_id","label","frequency","unit","country","release_lag_days")
  x$release_lag_days <- as.integer(x$release_lag_days);x
}

research_period_end <- function(date, frequency) {
  date <- as.Date(date)
  if(frequency=="monthly") return(as.Date(lubridate::ceiling_date(date,"month")-1))
  if(frequency=="quarterly") return(as.Date(lubridate::ceiling_date(date,"quarter")-1))
  date
}

research_rows <- function(id,date,value,frequency,unit,label,country="",currency="",source="",lag=0L,
                          available=NULL,revision="Latest revised data; historical release lag estimated") {
  date <- research_period_end(date,frequency)
  if(is.null(available)) available <- date+lag
  out <- data.frame(id=id,date=date,value=as.numeric(value),frequency=frequency,unit=unit,
    label=label,country=country,currency=currency,source=source,
    available_date=as.Date(available),revision=revision,stringsAsFactors=FALSE)
  out <- out[!is.na(out$date)&is.finite(out$value)&out$date<=book_date(),]
  out <- out[order(out$date),];rownames(out)<-NULL
  if(anyDuplicated(out$date)) stop("Duplicate observation periods: ",id)
  out
}

research_optional <- function(label, fun) {
  tryCatch(fun(),error=function(e) {
    message("Optional research source unavailable: ",label)
    structure(list(label=label,message=book_redact_text(conditionMessage(e))),class="research_unavailable")
  })
}

# Submit only the public site's own anonymous export forms, keeping its session.
research_rkr <- function(table="BM010",selection=list(var1="00",var2=c("1","2","3"),var3="REAL")) {
  book_fetch("Finans Danmark StatBank",list(table=table,selection=selection,format="PX",schema=1L),function() {
    file <- tempfile(fileext=".px")
    selection_file <- tempfile(fileext=".json")
    on.exit(unlink(c(file,selection_file)))
    jsonlite::write_json(selection,selection_file,auto_unbox=TRUE)
    status <- system2("python3",c("scripts/research_statbank.py",table,shQuote(selection_file),shQuote(file)))
    if(status!=0L) stop("Finans Danmark public export failed")
    raw <- readBin(file,"raw",n=file.info(file)$size)
    px <- pxR::read.px(file,encoding="latin1")
    list(data=as.data.frame(px),metadata=px[setdiff(names(px),"DATA")],raw=raw)
  })
}

research_oecd <- function() book_fetch("OECD analytical housing",list(countries=c("DNK","USA"),schema=1L),function() {
  url <- "https://sdmx.oecd.org/public/rest/v1/data/OECD.ECO.MPD,DSD_AN_HOUSE_PRICES@DF_HOUSE_PRICES,/DNK+USA.Q.."
  r <- httr::GET(url,httr::add_headers(Accept="text/csv;version=2.0"),httr::timeout(60))
  httr::stop_for_status(r)
  x <- utils::read.csv(text=httr::content(r,as="text",encoding="UTF-8"),check.names=FALSE)
  if(!all(c("REF_AREA","MEASURE","TIME_PERIOD","OBS_VALUE") %in% names(x))) stop("Unexpected OECD SDMX columns")
  x
})

research_japan_cpi <- function() book_fetch("OECD Japanese CPI",list(schema=2L),function() {
  url<-"https://sdmx.oecd.org/public/rest/v1/data/OECD.SDD.TPS,DSD_PRICES_COICOP2018@DF_PRICES_C2018_ALL,1.0/JPN.M.N.CPI.IX._T.N._Z"
  r<-httr::GET(url,httr::add_headers(Accept="text/csv;version=2.0"),httr::timeout(60))
  httr::stop_for_status(r)
  d<-utils::read.csv(text=httr::content(r,as="text",encoding="UTF-8"))
  if(!all(c("TIME_PERIOD","OBS_VALUE")%in%names(d)))stop("Unexpected OECD CPI columns")
  d
})

research_shiller <- function() book_fetch("Shiller valuation workbook",list(url="https://www.econ.yale.edu/~shiller/data/ie_data.xls"),function() {
  r <- httr::GET("https://www.econ.yale.edu/~shiller/data/ie_data.xls",httr::timeout(45));httr::stop_for_status(r)
  file <- tempfile(fileext=".xls");on.exit(unlink(file));writeBin(httr::content(r,as="raw"),file)
  x <- as.data.frame(readxl::read_excel(file,sheet="Data",skip=7,.name_repair="unique"))
  if(!all(c("Date","CAPE") %in% names(x))) stop("Unexpected Shiller workbook layout")
  x
})

research_dst <- function(table,selection) {
  book_fetch("Statistics Denmark research",list(table=table,selection=selection,schema=1L),function()
    dstcollect::dst_collect(table,selection))
}

research_data <- function() {
  path <- file.path(.book_runtime$snapshots,"research-prepared.rds")
  signature <- book_hash(list(code=readLines("scripts/analysis/research_data.R"),as_of=book_date(),run=.book_runtime$run_id))
  if(file.exists(path)) {
    old <- readRDS(path)
    if(identical(old$signature,signature)) return(old$value)
  }
  rows <- list();first <- list();unavailable <- list();raw <- list()
  add <- function(x) rows[[length(rows)+1L]] <<- x
  optional <- function(label,fun) {
    result <- research_optional(label,fun)
    if(inherits(result,"research_unavailable")) {unavailable[[label]] <<- result;return(NULL)}
    result
  }
  registry <- research_fred_registry()
  jp<-optional("Japanese CPI",research_japan_cpi)
  if(!is.null(jp))add(research_rows("jpy_cpi",as.Date(paste0(jp$TIME_PERIOD,"-01")),jp$OBS_VALUE,
    "monthly","index","Japanese consumer CPI, all items","JP","JPY",
    "https://data-explorer.oecd.org/",45L))
  for(i in seq_len(nrow(registry))) {
    m <- registry[i,];x <- optional(m$id,function() book_fred(m$source_id))
    if(is.null(x)) next
    add(research_rows(m$id,x$date,x$value,m$frequency,m$unit,m$label,m$country,
      if(m$country=="US"&&grepl("USD",m$unit)) "USD" else "",paste0("https://fred.stlouisfed.org/series/",m$source_id),m$release_lag_days))
    if(m$id %in% c("us_cpi","us_house","us_payroll","us_unemployment")) {
      f <- optional(paste0(m$id," first release"),function() book_fred(m$source_id,
        realtime_start=as.Date("1776-07-04"),realtime_end=book_date(),output_type=4L))
      if(!is.null(f)) first[[m$id]] <- research_rows(m$id,f$date,f$value,m$frequency,m$unit,m$label,m$country,
        source="FRED/ALFRED initial releases",available=f$realtime_start,revision="First-release values with recorded release dates")
    }
  }
  dst_specs <- list(
    dk_cpi=list("PRIS01",list(VAREGR="000000",ENHED="100",Tid="*"),"Danish consumer CPI","index",45L),
    dk_employees=list("LBESK103",list(BRANCHE1020="A-V",Tid="*"),"Danish employees, all industries, seasonally adjusted","people",65L),
    dk_labour=list("AKU100K",list(BESKSTATUS=c("BESTOT","AKUL","UARBST"),Tid="*"),"Danish labour force status, SA","thousand people",90L),
    dk_rates=list("AKU101K",list(BESKSTATUS=c("BFK","LPCT","EFK"),Tid="*"),"Danish labour force rates, SA","percent",90L),
    dk_build_counts=list("BYGV99",list(BYGFASE="*",ANVENDELSE=c("10000","10300","10400"),BYGHERRE="TOT",SÆSON="SÆSON",Tid="*"),"Danish residential construction, delay-adjusted, SA","dwellings",90L),
    dk_build_types=list("BYGV90",list(BYGFASE="*",ANVENDELSE=c("120","130","140"),Tid="*"),"Danish residential construction by type, delay-adjusted, NSA","dwellings",90L),
    dk_build_area=list("BYGV80",list(BYGFASE="*",ANVENDELSE=c("120","130","140"),Tid="*"),"Danish residential construction floor area, delay-adjusted, NSA","m2",90L),
    dk_construction_cost=list("PRIS90",list(BOLTYP="0111",ENHED="100",Tid="*"),"Danish construction producer prices; not resale house prices","index",90L))
  for(id in names(dst_specs)) {
    s <- dst_specs[[id]];x <- optional(id,function() research_dst(s[[1]],s[[2]]));if(is.null(x)) next
    raw[[id]] <- x;flat <- dstcollect::dst_as_tibble(x,"codes")
    dims <- setdiff(unique(x$series_dimensions$dimension_id),"ContentsCode")
    suffix <- if(length(dims)) do.call(paste,c(flat[dims],sep="_")) else rep("",nrow(flat))
    ids <- if(length(unique(suffix))==1L) rep(id,nrow(flat)) else paste(id,suffix,sep="_")
    if(startsWith(id,"dk_build")) ids <- paste(id,flat$ANVENDELSE,flat$BYGFASE,sep="_")
    for(key in unique(ids)) {
      d <- flat[ids==key,];label <- s[[3]]
      for(dim in dims) {
        dict <- x$categories[x$categories$dimension_id==dim,]
        label <- paste(label,dict$label[match(d[[dim]][1L],dict$category_code)],sep=" · ")
      }
      freq <- d$frequency[1L]
      add(research_rows(key,d$period_end,d$value,freq,s[[4]],label,"DK",source=paste0("https://api.statbank.dk/v1/tableinfo/",s[[1]]),lag=s[[5]]))
    }
  }
  assets <- research_assets()
  for(i in seq_len(nrow(assets))) {
    m <- assets[i,];x <- optional(m$id,function() book_yahoo(m$symbol));if(is.null(x)) next
    # Close represents the completed session. Do not use opening prices or invent weekend observations.
    value <- as.numeric(quantmod::Cl(x));dates <- as.Date(zoo::index(x))
    keep <- dates<book_date();
    add(research_rows(m$id,dates[keep],value[keep],"daily","price",m$label,currency=m$currency,
      source=paste0("https://finance.yahoo.com/quote/",m$symbol),available=dates[keep]+1L,
      revision="Historical closing prices; index price growth excludes dividends"))
  }
  for(term in c("3M","1Y","2Y","5Y","10Y","30Y")) {
    z<-optional(paste("ECB curve",term),function() book_ecb_data(paste0("YC.B.U2.EUR.4F.G_N_A.SV_C_YM.SR_",term),
      filter=list(startPeriod="1999-01-01"),attempts=1L))
    if(!is.null(z))add(research_rows(paste0("ecb_",tolower(term)),as.Date(z$obstime),z$obsvalue,"daily","percent",
      paste("Euro-area AAA spot yield",term),"EU","EUR","https://data.ecb.europa.eu/data/datasets/YC",1L))
  }
  h <- optional("Danish transaction prices",function() research_rkr())
  if(!is.null(h)) {
    raw$rkr <- h; d <- h$data
    # pxR names preserve the provider's Danish dimensions; codes come from PX metadata.
    time <- grep("^tid$",names(d),ignore.case=TRUE,value=TRUE); value <- tail(names(d),1L)
    property <- grep("ejendomskategori",names(d),ignore.case=TRUE,value=TRUE)
    if(length(time)==1L&&length(property)==1L) for(type in unique(as.character(d[[property]]))) {
      z <- d[as.character(d[[property]])==type,]
      q <- as.character(z[[time]]);dates <- as.Date(paste0(substr(q,1,4),"-",sprintf("%02d",(as.integer(substr(q,6,6))-1)*3+1),"-01"))
      id <- unname(c("Parcel-/rækkehus"="dk_house_houses","Ejerlejlighed"="dk_house_apartments","Fritidshus"="dk_house_holiday")[type])
      if(is.na(id)) id <- paste0("dk_house_",match(type,unique(as.character(d[[property]]))))
      add(research_rows(id,dates,z[[value]],"quarterly","DKK/m2",paste("DK realized transaction prices:",type),"DK","DKK","https://rkr.statistikbank.dk/BM010",90L))
    }
  }
  o <- optional("OECD housing valuation",research_oecd)
  if(!is.null(o)) {
    raw$oecd <- o
    for(country in c("DNK","USA")) for(measure in c("HPI_YDH","HPI_RPI")) {
      d <- o[o$REF_AREA==country & o$MEASURE==measure,]
      if(!nrow(d)) next
      q <- d$TIME_PERIOD;dates <- as.Date(paste0(substr(q,1,4),"-",sprintf("%02d",(as.integer(sub(".*Q","",q))-1L)*3L+1L),"-01"))
      id <- paste0(if(country=="DNK") "dk" else "us",if(measure=="HPI_YDH") "_price_income" else "_price_rent")
      add(research_rows(id,dates,d$OBS_VALUE,"quarterly","index (not a monetary multiple)",
        paste(country,if(measure=="HPI_YDH") "price-to-income index" else "price-to-rent index"),country,
        source="https://www.oecd.org/en/data/indicators/housing-prices.html",lag=120L))
    }
  }
  sh <- optional("S&P CAPE",research_shiller)
  if(!is.null(sh)) {
    d <- suppressWarnings(as.numeric(sh$Date));month <- round((d%%1)*100)
    keep <- is.finite(d)&d>1800&d<2100&month>=1&month<=12
    dates <- as.Date(sprintf("%04d-%02d-01",floor(d[keep]),round((d[keep]%%1)*100)))
    add(research_rows("us_cape",dates,sh$CAPE[keep],"monthly","ratio","Shiller CAPE: ten-year real earnings","US",source="https://www.econ.yale.edu/~shiller/data.htm",lag=45L))
  }
  observations <- do.call(rbind,rows)
  required <- c("dk_cpi","us_cpi","us_house","dk_house_bis","dk_build_counts_10000_3",
    "dk_employees","us_payroll","us_unemployment","yield_10","sp500","bitcoin")
  missing <- setdiff(required,unique(observations$id))
  if(length(missing)) stop("Essential research sources unavailable: ",paste(missing,collapse=", "))
  for(id in required) {
    d<-observations[observations$id==id,]
    maximum_age<-switch(d$frequency[1],daily=8L,monthly=210L,quarterly=240L,400L)
    if(as.integer(book_date()-max(d$date))>maximum_age)stop("Essential research source is stale: ",id)
  }
  result <- list(observations=observations,first_release=first,raw=raw,unavailable=unavailable,
    assets=assets,as_of=book_date(),registry=registry)
  book_save_rds(list(signature=signature,value=result),path)
  result
}
