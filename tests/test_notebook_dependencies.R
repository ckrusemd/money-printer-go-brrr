# Notebook/package audits must discover static imports without treating wrapper
# arguments such as library(package, character.only=TRUE) as package names.
source("scripts/check_publication_dependencies.R")
packages <- publication_dependencies()
lock <- jsonlite::read_json("renv.lock")
bundled <- rownames(installed.packages(priority=c("base", "recommended")))
stopifnot(!"package" %in% packages,
          all(c("IRkernel", "IRdisplay", "repr", "plotly", "DT", "visNetwork") %in% packages),
          all(packages %in% c(names(lock$Packages), bundled)))
cat("Notebook dependency declarations are all locked\n")

# R normalizes separators in versions (Formula 1.2-5 prints as 1.2.5).
# Equivalent locked versions must pass; actual dependency drift must still fail.
local({
  audit <- normalizePath("scripts/notebooks/environment.R")
  previous <- getwd()
  temporary <- tempfile("notebook-environment-")
  dir.create(temporary)
  on.exit({ setwd(previous); unlink(temporary, recursive = TRUE) })
  setwd(temporary)
  installed <- as.character(utils::packageVersion("Formula"))
  equivalent <- sub("^(.*)\\.([0-9]+)$", "\\1-\\2", installed)
  stopifnot(package_version(equivalent) == package_version(installed))
  fixture <- list(R = list(Version = as.character(getRversion())),
                  Packages = list(Formula = list(Version = equivalent)))
  jsonlite::write_json(fixture, "renv.lock", auto_unbox = TRUE)
  source(audit)
  fixture$Packages$Formula$Version <- "0.0.0"
  jsonlite::write_json(fixture, "renv.lock", auto_unbox = TRUE)
  error <- tryCatch({ source(audit); NULL }, error = identity)
  stopifnot(inherits(error, "error"),
            grepl("Locked version mismatch: Formula", conditionMessage(error)))
})
cat("Notebook environment accepts normalized versions and rejects real drift\n")
