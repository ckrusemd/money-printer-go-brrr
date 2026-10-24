fixture_transport <- function(lang="da") {
  calls <- list()
  meta <- list(id="TEST",text="Test",unit="Indeks",updated="2026-01-01T08:00:00",
    variables=list(
      list(id="AREA",text="område",time=FALSE,elimination=FALSE,
        values=list(list(id="001",text="Samme navn"),list(id="002",text="Samme navn"))),
      list(id="Tid",text="tid",time=TRUE,elimination=FALSE,
        values=list(list(id="2024K1",text="2024K1"),list(id="2024K2",text="2024K2"),list(id="2024K3",text="2024K3")))))
  transport <- function(endpoint,p) {
    calls[[length(calls)+1L]] <<- list(endpoint=endpoint,p=p)
    if (endpoint=="tableinfo") return(meta)
    if (endpoint=="tables") return(list(meta))
    if (endpoint=="subjects") return(list(list(id="01",description="Befolkning",subjects=list(list(id="02",description="Underemne",tables=list(meta))))))
    vars <- stats::setNames(lapply(p$variables,function(v) unlist(v$values)),vapply(p$variables,`[[`,character(1),"code"))
    area <- vars$AREA; time <- vars$Tid
    make_dim <- function(values) list(label="label",category=list(index=as.list(stats::setNames(seq_along(values)-1L,values)),label=as.list(stats::setNames(values,values))))
    g <- expand.grid(Tid=time,AREA=area,stringsAsFactors=FALSE)
    values <- as.list(as.numeric(g$AREA)*10+match(g$Tid,c("2024K1","2024K2","2024K3")))
    list(dataset=list(dimension=list(AREA=make_dim(area),Tid=make_dim(time),id=list("AREA","Tid"),size=as.list(c(length(area),length(time))),role=list(time=list("Tid"))),value=values))
  }
  list(transport=transport,calls=function() calls,meta=meta)
}

test_that("all endpoints share typed components and discovery preserves hierarchy", {
  f <- fixture_transport(); m <- dst_metadata("TEST",transport=f$transport)
  expect_identical(names(m),names(dst_subjects(transport=f$transport)))
  expect_identical(names(m),names(dst_tables(transport=f$transport)))
  expect_s3_class(m$data,"tbl_df");expect_s3_class(m$data$period_start,"Date")
  expect_equal(m$categories$category_code[1:2],c("001","002"))
  expect_equal(dst_subjects(transport=f$transport)$subjects$parent_id,c(NA,"01"))
  expect_equal(nrow(dst_search("test",transport=f$transport)$tables),1)
  expect_equal(nrow(dst_search("not here",transport=f$transport)$tables),0)
  expect_error(dst_metadata("TEST",lang="fr",transport=f$transport),"lang")
})

test_that("chunking reproduces the complete extract and stable identities", {
  f <- fixture_transport(); selection <- list(AREA="*",Tid="*")
  a <- dst_collect("TEST",selection,transport=f$transport)
  b <- dst_collect("TEST",selection,max_cells=10,transport=f$transport)
  expect_equal(a$data[setdiff(names(a$data),"request_id")],b$data[setdiff(names(b$data),"request_id")])
  expect_equal(nrow(a$data),6)
  expect_equal(nrow(a$series),2)
  expect_true(sum(vapply(f$calls(),function(x) x$endpoint=="data",logical(1)))>2)
  c <- dst_collect("TEST",selection,lang="en",transport=f$transport)
  expect_identical(a$data$series_id,c$data$series_id)
  view <- dst_as_tibble(a,"codes")
  expect_equal(sort(unique(view$AREA)),c("001","002"))
  expect_equal(unique(dst_as_tibble(a,"labels")$AREA),"Samme navn")
})

test_that("selectors are explicit and resolve using metadata rather than labels", {
  f <- fixture_transport();m <- dst_metadata("TEST",transport=f$transport)
  expect_equal(dst_query(m),list(AREA="*",Tid="*"))
  expect_error(dst_collect("TEST",list(AREA="*"),transport=f$transport),"every")
  expect_error(dst_collect("TEST",list(AREA="Samme navn",Tid="*"),transport=f$transport),"Unknown")
  expect_error(dst_collect("TEST",list(AREA="*",Tid="sum(2024K1;2024K2)"),transport=f$transport),"calculations")
  x <- dst_collect("TEST",list(AREA="00*",Tid=">=2024K2<=2024K3"),transport=f$transport)
  expect_equal(nrow(x$data),4)
  expect_equal(unique(dst_collect("TEST",list(AREA="001",Tid="(1)"),transport=f$transport)$data$period_code),"2024K3")
})

test_that("missing cells and unknown period formats remain explicit", {
  expect_equal(dstcollect:::decode_values(list(`1`=2),3),c(NA,2,NA))
  expect_equal(dstcollect:::decode_values(list(1,NULL,3),3),c(1,NA,3))
  p <- dstcollect:::periods(c("2024","2024K1","2024M02","2024H2","2024-02-29","2024U01","2024M13"))
  expect_equal(as.character(p$period_end[1:5]),c("2024-12-31","2024-03-31","2024-02-29","2024-12-31","2024-02-29"))
  expect_true(all(is.na(p$period_start[6:7])))
  expect_equal(p$frequency[6:7],rep("unknown",2))
})

test_that("partial chunks, changed metadata and conflicting duplicates fail", {
  f <- fixture_transport(); n <- 0
  failed <- function(e,p) {if(e=="data") {n <<- n+1;if(n==2) stop("unavailable chunk")};f$transport(e,p)}
  expect_error(dst_collect("TEST",list(AREA="*",Tid="*"),max_cells=10,transport=failed),"unavailable chunk")
  n <- 0
  changed <- function(e,p) {x <- f$transport(e,p);if(e=="tableinfo") {n <<- n+1;if(n>1) x$updated <- "different"};x}
  expect_error(dst_collect("TEST",list(AREA="*",Tid="*"),transport=changed),"changed")
  a <- dst_collect("TEST",list(AREA="*",Tid="*"),transport=f$transport);b <- a;b$data$value[1] <- -1
  expect_error(dst_bind(a,b),"Conflicting")
  expect_equal(nrow(dst_bind(a,a)$data),nrow(a$data))
})

test_that("curated concepts distinguish house categories and percent measures", {
  f <- fixture_transport(); a <- dst_collect("TEST",list(AREA="*",Tid="*"),transport=f$transport)
  expect_equal(nrow(a$concepts),0)
  m <- utils::read.csv(system.file("concepts.csv",package="dstcollect"),colClasses="character")
  expect_equal(m$concept_code[m$table_id=="BYGV80" & m$dimension_id=="ANVENDELSE" & m$category_code=="120"],"detached_house")
  expect_equal(m$concept_code[m$table_id=="PRIS90" & m$dimension_id=="BOLTYP"],"single_family_house")
  expect_false(anyDuplicated(m[c("table_id","dimension_id","category_code","concept")])>0)
  a$concepts <- tibble::tibble(table_id="TEST",series_id=a$series$series_id[1],dimension_id="AREA",category_code="001",concept="measure",concept_code="period_change_percent",relationship="exact",mapping_version="1",evidence="fixture")
  b <- dstcollect:::apply_measure_units(a)
  expect_true(all(b$data$unit[b$data$series_id==a$series$series_id[1]]=="percent"))
  expect_error(dst_legacy_series(a),"collision")
  aliases <- dst_legacy_series(a,series_cols="AREA",code_labels=TRUE)
  expect_equal(nrow(aliases),nrow(a$data))
  expect_equal(length(attr(aliases,"canonical_series_id")),nrow(a$data))
  expect_equal(length(unique(aliases$series)),2L)
})
