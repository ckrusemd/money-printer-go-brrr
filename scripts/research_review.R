# Deliberately separate expensive model selection from the daily book render.
source("scripts/notebooks/bootstrap.R")
source("scripts/analysis/research_views.R")
args<-commandArgs(trailingOnly=TRUE)
output<-if(length(args))args[1L] else ".cache/research-models"
data<-research_data()
research_validate_data(data)
review<-research_review(data,output)
stopifnot(nrow(review$records)>0L,nrow(review$scores)>0L)
utils::write.csv(review$scores,file.path(output,"scores.csv"),row.names=FALSE)
jsonlite::write_json(list(schema=1L,signature=review$signature,
  review_date=as.character(review$review_date),records=nrow(review$records),
  targets=length(unique(review$records$id)),source_hash=review$source_hash,
  config=review$config),file.path(output,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat("Completed review:",nrow(review$records),"predictions across",
  length(unique(review$records$id)),"targets\n")
