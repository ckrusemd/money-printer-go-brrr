book_load_packages(fredr,
               dplyr,
               tidyr,
               lubridate,
               caret,
               partykit,
               pROC,
               devtools,
               gridExtra,
               httr,
               DT,
               httr,
               glue,
               visNetwork,
               data.table,
               pROC,
               rPref,
               progress,
               quantmod,
               rvest,
               ggrepel)

# Shared explicit dependency for independently executed market notebooks.
# Call book_market_setup() explicitly; source responses and prepared data are reused only within a build.
book_cpi_base <- function(date,value,base="2015-01") {
  at<-which(format(as.Date(date),"%Y-%m")==base)
  if(length(at)!=1L||!is.finite(value[at])||value[at]<=0)stop("Missing or ambiguous CPI base month: ",base)
  100*value/value[at]
}

book_prepare_market_data <- function() {
options(repr.plot.width = 10, repr.plot.height = 7, repr.plot.res = 120)
# Consumer CPI; PRIS01 replaces the archived PRIS111. Net prices exclude
# indirect taxes and are unsuitable for a consumer purchasing-power deflator.
df_PRIS114 = book_dst(table = "PRIS01",
                     VAREGR = "000000",
                     ENHED = "100",
                     Tid = "*") %>%
  dplyr::mutate(TID=as.Date(TID)) %>%
  arrange(TID) %>%
  dplyr::mutate(value=book_cpi_base(TID,value),Index=value/100) %>%
  tidyr::complete(TID=seq.Date(from=min(TID,na.rm=T),to=book_date(),by="1 day")) %>%
  tidyr::fill(TID,.direction = "down")  %>%
  tidyr::fill(value,.direction = "down")   %>%
  tidyr::fill(VAREGR,.direction = "down")   %>%
  tidyr::fill(ENHED,.direction = "down")    %>%
  tidyr::fill(Index,.direction = "down") %>%
  dplyr::select(TID,value) %>%
  dplyr::rename(date=TID) %>%
  dplyr::mutate(series_id="PRICE_INDEX",
                currency="DKK")


options(repr.plot.width = 10, repr.plot.height = 7, repr.plot.res = 120)
df_CPIAUCNS = book_fred("CPIAUCNS") %>%
    dplyr::select(series_id,
                  date,
                  value) %>%
    tidyr::complete(date=seq.Date(from=min(date,na.rm=T),to=book_date(),by="1 day")) %>%
    tidyr::fill(value,.direction = "down") %>%
    tidyr::fill(series_id,.direction = "down") %>%
  dplyr::mutate(index=ifelse(date==ymd("2015-01-01"),value,NA)) %>%
  tidyr::fill(index,.direction = "downup") %>%
  dplyr::mutate(value=100*value/index,
                series_id="PRICE_INDEX",
                currency="USD") %>%
  dplyr::select(-index)


options(repr.plot.width = 10, repr.plot.height = 7, repr.plot.res = 120)
df_nominal = expand.grid(currency=c("USD","DKK"),
                         value=1,
                         series_id="NOMINAL",
                         date=seq.Date(min(df_CPIAUCNS$date),max(df_CPIAUCNS$date),by="1 day"))


options(repr.plot.width = 10, repr.plot.height = 7, repr.plot.res = 120)
series_ids_yahoo = unique(c("CL=F",
                            "GC=F",
                            "SI=F",
                            "BTC-USD",
                            "DKKUSD=X",
                            "USDDKK=X"))

df_macro_yahoo = rbindlist(lapply(series_ids_yahoo,function(ticker) {
      temp_df = book_yahoo(ticker, env = NULL) %>%
      as.data.frame(.) %>%
      dplyr::mutate(Date=row.names(.)) %>%
      dplyr::mutate(Date=gsub("X","",Date)) %>%
      dplyr::mutate(Date=ymd(Date)) %>%
      dplyr::select(c(7,1)) %>%
      setNames(.,c("date","value")) %>%
      dplyr::mutate(series_id=ticker) %>%
      tidyr::complete(date=seq.Date(from=min(date,na.rm=T),to=book_date(),by="1 day")) %>%
      tidyr::fill(value,.direction = "down")  %>%
      tidyr::fill(series_id,.direction = "down")

      row.names(temp_df) = NULL
      return( temp_df )
}))

# USD
df_macro_yahoo_usd = df_macro_yahoo %>%
  filter(!series_id=="USDDKK=X") %>%
  dplyr::mutate(currency="USD")

# DKK
df_macro_yahoo_dkk = df_macro_yahoo %>%
  inner_join( df_macro_yahoo %>% filter(series_id=="USDDKK=X") %>% dplyr::select(date,value) %>% dplyr::rename(usd=value)) %>%
  filter(!series_id=="DKKUSD=X") %>%
  dplyr::mutate(value=value*usd,
                currency="DKK") %>%
  dplyr::select(-usd)

df_macros = df_macro_yahoo_usd %>%
  bind_rows( df_macro_yahoo_dkk ) %>%
  bind_rows(df_CPIAUCNS) %>%
  bind_rows(df_PRIS114) %>%
  bind_rows(df_nominal)


options(repr.plot.width = 10, repr.plot.height = 7, repr.plot.res = 120)
series_ids_yahoo = unique(c("GC=F",
                            "SI=F",
                            "BTC-USD",
                            "ETH-USD",
                            "^RUT",
                            "^W5000",
                            "^IXIC",
                            "^GSPC",

                            "SHV",
                            "TBF",
                            "TTT",
                            "TBX",
                            "PST",
                            "TBT",

                            "XLK",
                            "XLV",
                            "XLY",
                            "XLP",
                            "XLU",
                            "XLF",
                            "XLI",
                            "XLB",
                            "XLE",
                            "XLRE",
                            "XLC",

                            "REW",
                            "RXD",
                            "SCC",
                            "SDP",
                            "SKF",
                            "SIJ",
                            "SMN",
                            "DUG",
                            "SRS",

                            "MBB",
                            "GOVT",
                            "SGOV",
                            "SHY",
                            "IEI",
                            "IEF",
                            "UST",
                            "UBT",
                            "TLH",
                            "TLT",

                            "^OMXC25"))

get_yahoo_ticker = function(ticker, attempts = 3) {
  for (attempt in seq_len(attempts)) {
    temp_df = tryCatch(
      book_yahoo(ticker, env = NULL, attempts = 1L),
      error = function(error) NULL
    )

    if (!is.null(temp_df)) {
      return(
        temp_df %>%
      as.data.frame(.) %>%
      dplyr::mutate(Date=row.names(.)) %>%
      dplyr::mutate(Date=gsub("X","",Date)) %>%
      dplyr::mutate(Date=ymd(Date)) %>%
      dplyr::select(c(7,1)) %>%
      setNames(.,c("date","price")) %>%
      dplyr::mutate(ticker=ticker) %>%
      tidyr::complete(date=seq.Date(from=min(date,na.rm=T),to=book_date(),by="1 day")) %>%
      tidyr::fill(price,.direction = "down")  %>%
      tidyr::fill(ticker,.direction = "down")
      )
    }

    if (attempt < attempts) Sys.sleep(2 ^ (attempt - 1))
  }

  warning(sprintf("Skipping Yahoo Finance ticker %s after %d failed attempts", ticker, attempts))
  NULL
}

df_tickers_yahoo = rbindlist(lapply(series_ids_yahoo, get_yahoo_ticker), fill = TRUE)


options(repr.plot.width = 10, repr.plot.height = 7, repr.plot.res = 120)
df_adjusted = df_tickers_yahoo %>%
  inner_join( df_macros ) %>%
  dplyr::mutate(index=price/value) %>%
  dplyr::select(-price,-value)


options(repr.plot.width = 10, repr.plot.height = 7, repr.plot.res = 120)
  list(df_adjusted = df_adjusted, df_tickers_yahoo = df_tickers_yahoo)
}

market_chart_description <- function(label, currency) {
  paste0(
    label, " indicator panels, quoted in ", currency, ". ",
    "Top to bottom: full price history with support lines where specified; ",
    "past-year prices; latest indicator heatmap with numerical labels; ",
    "price minus its 200-observation simple moving average; ",
    "30-observation relative strength index with reference lines at 20 and 70; ",
    "currency and crude oil, silver, and gold comparisons where available, ",
    "with unavailable FX comparison data labeled in its panel; ",
    "nominal and inflation-adjusted series rebased to January 2015 where baseline history exists; ",
    "and the difference between those rebased series. ",
    "Dates run left to right. Non-trading days carry prices forward. ",
    "Missing price histories, insufficient indicator histories, and missing 2015 baselines are marked unavailable."
  )
}

draw_plots = function(data,lines=NA) {
  if (nrow(data) == 0 || !any(is.finite(data$index))) {
    return(
      ggplot() +
        theme_void() +
        labs(title = "Market data unavailable",
             subtitle = "No usable price history was returned for this ticker")
    )
  }

  ticker_ = unique(data$ticker)
  temp_df = data %>% filter(ticker==ticker_)

  # Lines
  df_lines = temp_df %>%
    filter(series_id=="NOMINAL")

  if (unique(!is.na(lines))) {
  df_lines = rbindlist(lapply(seq(length(lines)),function(line) {

    df_lines %>%
      dplyr::mutate(series_id="SUPPORT",
                    predicted=predict(
        df_lines %>%
          filter(date %in% lines[[line]]) %>%
          lm(index~date,data=.),
        .)) %>%
      dplyr::mutate(category=paste0("line",line))

  }))
  } else {
  df_lines = data.frame()
  }

# All time plot
p1 = temp_df %>%
  filter(series_id=="NOMINAL") %>%
  ggplot(.,aes(x=date,y=index)) +
  geom_line() +
  theme_money_printer_go_brrr(12) +
  theme(legend.position = "bottom") +
  scale_x_date(date_labels = "%Y",date_breaks = "5 years") +
  scale_y_continuous(limits = c(0,NA)) +
  labs(x=NULL,y=NULL,title=glue("{ticker_}"),subtitle="All Time")
if (nrow(df_lines)>0) {
  p1 = p1 +
    geom_line(data=df_lines,aes(x=date,y=predicted,color=category,group=category),linetype=2)
}

# Last year
p2 = temp_df %>%
  filter(series_id=="NOMINAL") %>%
  filter(date>=book_date()-years(1)) %>%
  ggplot(.,aes(x=date,y=index)) +
  geom_line() +
  theme_money_printer_go_brrr(12) +
  theme(legend.position = "bottom") +
  scale_x_date(date_labels = "%b",date_breaks = "1 month",limits = c(book_date()-years(1),NA)) +
  geom_vline(xintercept = book_date(),linetype=2) +
  labs(x=NULL,y=NULL,subtitle="Last Year")





# Indicator heatmap
indicator_data = temp_df %>%
  filter(series_id=="NOMINAL") %>%
  arrange((date))

indicator_index <- indicator_data$index
safe_indicator <- function(minimum_observations, calculation) {
  if (sum(is.finite(indicator_index)) < minimum_observations) {
    return(rep(NA_real_, length(indicator_index)))
  }
  tryCatch(calculation(), error = function(error) {
    rep(NA_real_, length(indicator_index))
  })
}

if (sum(is.finite(indicator_index)) < 200) {
  p2b <- ggplot() +
    theme_void() +
    labs(subtitle = "Indicators unavailable: insufficient price history")
} else {
  p2b <- indicator_data %>%
  dplyr::mutate(value_rsi=safe_indicator(15, function() TTR::RSI(indicator_index)),
                value_macd=safe_indicator(26, function() {
                  macd <- TTR::MACD(indicator_index)
                  macd[,1] - macd[,2]
                }),
                value_cci=safe_indicator(20, function() TTR::CCI(indicator_index)),
                value_goldencross=safe_indicator(200, function() {
                  TTR::SMA(indicator_index,n=50) - TTR::SMA(indicator_index,n=200)
                })) %>%
  dplyr::mutate(value_lastdate=ifelse(index<last(index) & !date==max(date),as.Date(date),as.Date(NA))) %>%
  dplyr::mutate(value_lastdate=if (all(is.na(value_lastdate))) NA_real_ else max(value_lastdate,na.rm=T)) %>%
  dplyr::mutate(value_lastdate=as.numeric(date-as.Date(value_lastdate))) %>%
  tidyr::fill(value_lastdate,.direction = "down") %>%
  dplyr::mutate(p_rsi=pnorm(value_rsi,mean=mean(value_rsi,na.rm=T),sd=sd(value_rsi,na.rm=T)),
                p_macd=pnorm(value_macd,mean=mean(value_macd,na.rm=T),sd=sd(value_macd,na.rm=T)),
                p_cci=pnorm(value_cci,mean=mean(value_cci,na.rm=T),sd=sd(value_cci,na.rm=T)),
                p_goldencross=pnorm(value_goldencross,mean=mean(value_goldencross,na.rm=T),sd=sd(value_goldencross,na.rm=T)),
                p_pnorm=pnorm(index,mean=mean(tail(index,3*365),na.rm=T),sd=sd(tail(index,3*365),na.rm=T)),
                p_lastdate=0.5) %>%
  filter(date==max(date)) %>%
  dplyr::select(-currency,-index) %>%
  gather(stat,val,value_rsi:p_lastdate) %>%
  separate(stat,into=c("type","metric")) %>%
  spread(type,val) %>%
  ggplot(aes(x=metric,y=ticker,fill=p)) +
  geom_tile() +
  geom_text(aes(label=ifelse(metric=="pnorm",
                           ifelse(is.finite(p),scales::percent(p,0.1),"Unavailable"),
                           paste0(scales::number(value,0.01)," (",scales::percent(p,0.1),")"))),color="white") +
  scale_x_discrete(labels=function(metric) ifelse(metric=="pnorm","Price percentile",metric)) +
  scale_fill_gradientn(colours=hcl.colors(10, palette = "ag_GrnYl"),
                       na.value = "transparent",
                       breaks=c(0,0.5,1),
                       labels=c("Minimum",0.5,"Maximum"),
                       limits=c(0,1)) +
  theme_money_printer_go_brrr(12) +
  theme(legend.position="null",
        axis.text.y=element_blank()) +
    labs(x=NULL,y=NULL)
}

# SMA
p3 = temp_df %>%
  filter(series_id=="NOMINAL") %>%
  arrange(date) %>%
  dplyr::mutate(sma200=safe_indicator(200, function() TTR::SMA(indicator_index,n=200))) %>%
  dplyr::mutate(index=index-sma200) %>%
  filter(date>=book_date()-years(1)) %>%
  ggplot(.,aes(x=date,y=index)) +
  geom_line() +
  theme_money_printer_go_brrr(12) +
  scale_x_date(date_labels = "%b",date_breaks = "1 month") +
  geom_hline(yintercept = 0,linetype=2) +
  labs(x=NULL,y=NULL,subtitle="SMA 200")

# RSI
p4 = temp_df %>%
  filter(series_id=="NOMINAL") %>%
  arrange(date) %>%
  dplyr::mutate(rsi=safe_indicator(31, function() TTR::RSI(indicator_index,n=30))) %>%
  filter(date>=book_date()-years(1)) %>%
  ggplot(.,aes(x=date,y=rsi)) +
  geom_line() +
  theme_money_printer_go_brrr(12) +
  scale_x_date(date_labels = "%b",date_breaks = "1 month") +
  geom_hline(yintercept = c(20,70),linetype=2) +
  labs(x=NULL,y=NULL,title="RSI (30 observations)",subtitle=NULL) +
  theme(plot.title=element_text(size=12),plot.title.position="plot")

# Real terms (US)
p5 = temp_df %>%
  filter(series_id=="PRICE_INDEX") %>%
  ggplot(.,aes(x=date,y=index)) +
  geom_line() +
  theme_money_printer_go_brrr(12) +
  scale_x_date(date_labels = "%Y",date_breaks = "1 year") +
  labs(x=NULL,y=NULL,subtitle="Real Terms (US)")

# US Dollars
p6 = temp_df %>%
  filter(series_id=="USDDKK=X") %>%
  ggplot(.,aes(x=date,y=index)) +
  geom_line() +
  theme_money_printer_go_brrr(12) +
  scale_x_date(date_labels = "%Y",date_breaks = "1 year") +
  labs(x=NULL,y=NULL,subtitle="DKK")

if (!any(is.finite(temp_df$index[temp_df$series_id == "USDDKK=X"]))) {
  p6 <- ggplot() +
    theme_void() +
    annotate("text", x = 0, y = 0,
             label = "FX comparison data unavailable for this chart", size = 3.5) +
    labs(subtitle = "DKK")
}

# Oil
p7 = temp_df %>%
  filter(series_id=="CL=F") %>%
  ggplot(.,aes(x=date,y=index)) +
  geom_line() +
  theme_money_printer_go_brrr(12) +
  scale_x_date(date_labels = "%Y",date_breaks = "1 year") +
  scale_y_continuous(limits=c(0,150)) +
  labs(x=NULL,y=NULL,subtitle="Crude Oil")

# Silver
p8 = temp_df %>%
  filter(series_id=="SI=F") %>%
  ggplot(.,aes(x=date,y=index)) +
  geom_line() +
  theme_money_printer_go_brrr(12) +
  scale_x_date(date_labels = "%Y",date_breaks = "1 year") +
  labs(x=NULL,y=NULL,subtitle="Silver")

# Gold
p9 = temp_df %>%
  filter(series_id=="GC=F") %>%
  ggplot(.,aes(x=date,y=index)) +
  geom_line() +
  theme_money_printer_go_brrr(12) +
  scale_x_date(date_labels = "%Y",date_breaks = "1 year") +
  labs(x=NULL,y=NULL,subtitle="Gold")

  # Index
  p10 = temp_df  %>%
    filter(series_id %in% c("PRICE_INDEX","NOMINAL")) %>%
    group_by(series_id) %>%
    dplyr::mutate(nominal_2015=ifelse(date==ymd("2015-01-01"),index,NA)) %>%
    tidyr::fill(nominal_2015,.direction = "downup") %>%
    ungroup() %>%
    dplyr::mutate(index=100*index/nominal_2015) %>%
    dplyr::select(-nominal_2015) %>%
    ggplot(aes(x=date,y=index,color=series_id,group=series_id)) +
    geom_line() +
    theme_money_printer_go_brrr(12) +
    scale_x_date(date_labels = "%Y",date_breaks = "1 year") +
    labs(x=NULL,y=NULL,subtitle="Indexed 2015")

  # Above/below price index
  p11 = temp_df  %>%
    filter(series_id %in% c("PRICE_INDEX","NOMINAL")) %>%
    group_by(series_id) %>%
    dplyr::mutate(nominal_2015=ifelse(date==ymd("2015-01-01"),index,NA)) %>%
    tidyr::fill(nominal_2015,.direction = "downup") %>%
    ungroup() %>%
    dplyr::mutate(index=100*index/nominal_2015) %>%
    dplyr::select(-nominal_2015) %>%
    dplyr::mutate(priceindex=ifelse(series_id=="PRICE_INDEX",index,NA)) %>%
    tidyr::fill(priceindex,.direction = "downup") %>%
    dplyr::mutate(index=index-priceindex) %>%
    filter(!series_id=="PRICE_INDEX") %>%
    ggplot(aes(x=date,y=index,color=series_id,group=series_id)) +
    geom_line() +
    theme_money_printer_go_brrr(12) +
    scale_x_date(date_labels = "%Y",date_breaks = "1 year") +
    labs(x=NULL,y=NULL,subtitle="Above/below price trend") +
    geom_hline(yintercept = 0,linetype=2)

  # Annotate absent baseline history without changing either rebasing calculation.
  missing_2015 <- setdiff(c("NOMINAL","PRICE_INDEX"),
    temp_df$series_id[temp_df$date==ymd("2015-01-01") & is.finite(temp_df$index)])
  if (length(missing_2015)) {
    baseline_message <- paste0("2015 rebasing unavailable for ",
      paste(ifelse(missing_2015=="NOMINAL","nominal prices","inflation-adjusted prices"),collapse=" and "),
      "\nNo usable observation on 2015-01-01")
    p10_has_values <- any(is.finite(p10$data$index))
    p10 <- p10 + annotate("text",x=min(p10$data$date),y=if (p10_has_values) Inf else 0,
                         label=baseline_message,hjust=0,vjust=if (p10_has_values) 1.2 else 0.5,size=3.5)
    p11 <- p11 + annotate("text",x=min(p11$data$date),y=Inf,
                         label=baseline_message,hjust=0,vjust=1.2,size=3.5)
    if (!p10_has_values) p10 <- p10 + guides(colour="none")
    if (!any(is.finite(p11$data$index))) p11 <- p11 + guides(colour="none")
  }

p_all = grid.arrange(p1,p2,p2b,p3,p4,
                     # p5,
                     p6,p7,p8,p9,p10,p11,ncol=1)
print(p_all)

}


options(repr.plot.width = 10, repr.plot.height = 7, repr.plot.res = 120)
draw_market_snapshot <- function(symbol_, currency_, label_) {
  prices <- df_tickers_yahoo %>%
    dplyr::filter(.data$ticker == .env$symbol_,
                  is.finite(.data$price),
                  .data$date >= book_date() - lubridate::years(1)) %>%
    dplyr::arrange(.data$date)

  if (nrow(prices) == 0) {
    return(
      ggplot() +
        theme_void() +
        labs(title = label_,
             subtitle = "Price data unavailable")
    )
  }

  p <- ggplot(prices, aes(x = date, y = price)) +
    geom_line(linewidth = 0.6) +
    theme_money_printer_go_brrr(11) +
    scale_x_date(date_labels = "%b %Y", date_breaks = "3 months") +
    labs(title = label_,
         subtitle = "Opening price · past 12 months",
         x = NULL, y = currency_,
         caption = "Source: Yahoo Finance · non-trading days carried forward")
  plotly::layout(plotly::ggplotly(p, tooltip = c("x", "y")),
                 xaxis = list(rangeslider = list(visible = TRUE)))

}



book_market_setup <- function(envir = parent.frame()) {
  signature <- book_hash(list(code = body(book_prepare_market_data),
                              lock = readLines("renv.lock", warn = FALSE),
                              as_of = book_date()))
  path <- file.path(.book_runtime$snapshots, "market-prepared.rds")
  reusable <- .book_runtime$mode == "record" && nzchar(.book_runtime$run_id)
  record <- if (reusable && file.exists(path)) readRDS(path) else NULL
  if (is.list(record) && identical(record$run_id, .book_runtime$run_id) &&
      identical(record$signature, signature)) {
    data <- record$data
  } else {
    data <- book_prepare_market_data()
    if (reusable) book_save_rds(list(run_id = .book_runtime$run_id,
                                    signature = signature, data = data), path)
  }
  list2env(data, envir = envir)
  invisible(data)
}
