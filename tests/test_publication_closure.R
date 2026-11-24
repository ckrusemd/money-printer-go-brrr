# Base-R-only fixtures: no installed publication packages or network required.
source("scripts/check_publication_closure.R")

local({
  record <- function(package, ...) list(Package = package, Version = "1.0", ...)
  records <- list(
    app = record("app", Depends = "R (>= 4.3), recommended (>= 1.0)",
                 Imports = list("worker (>= 1.0)", "stats"), LinkingTo = "headers",
                 Suggests = "optional"),
    worker = record("worker", Imports = "app, bundledRecommended"),
    headers = record("headers"),
    recommended = record("recommended", Imports = "headers"),
    optional = record("optional"),
    notebook = record("notebook"))
  bundled <- c("stats", "recommended", "bundledRecommended")
  roots <- c("app", "app", "stats")
  root <- list(R = list(Version = "4.3.3"), Packages = records)
  expect_error <- function(expression, message) {
    error <- tryCatch({ force(expression); NULL }, error = identity)
    stopifnot(inherits(error, "error"), grepl(message, conditionMessage(error), fixed = TRUE))
  }

  closure <- publication_lock_closure(roots, records, bundled)
  # A dependency cycle terminates; string/list fields and version constraints parse.
  stopifnot(identical(closure$mandatory, c("app", "headers", "recommended", "worker")),
            identical(closure$roots, c("app", "stats")),
            identical(closure$bundled, c("bundledRecommended", "stats")),
            identical(closure$candidates, c("notebook", "optional")))
  # Full locks and conservative identical-record subsets are both valid.
  full <- audit_publication_closure(root, root, roots, bundled)
  stopifnot(full$preserves_all, length(full$retained) == 6L)
  subset <- root
  subset$Packages <- records[closure$mandatory]
  stopifnot(!audit_publication_closure(root, subset, roots, bundled)$preserves_all)
  subset$Packages$optional <- records$optional
  stopifnot(length(audit_publication_closure(root, subset, roots, bundled)$retained) == 5L)

  for (package in closure$mandatory) {
    incomplete <- root
    incomplete$Packages[[package]] <- NULL
    expect_error(audit_publication_closure(root, incomplete, roots, bundled),
                 "omits mandatory dependencies")
  }
  # Lock records remain authoritative, including locked recommended versions.
  for (field in c("Version", "Imports", "Source")) {
    drifted <- root
    drifted$Packages$recommended[[field]] <- "changed"
    expect_error(audit_publication_closure(root, drifted, roots, bundled), "records differ from root")
  }
  drifted <- root
  drifted$R$Version <- "4.4.0"
  expect_error(audit_publication_closure(root, drifted, roots, bundled), "R configuration differs")
  extra <- root
  extra$Packages$foreign <- record("foreign")
  expect_error(audit_publication_closure(root, extra, roots, bundled), "records absent from root")
  expect_error(publication_lock_closure("missingRoot", records, bundled), "Missing lock dependency")
  broken <- records
  broken$headers$LinkingTo <- "missingHeader (>= 1.0)"
  expect_error(publication_lock_closure(roots, broken, bundled), "Missing lock dependency: missingHeader")
  stopifnot(length(publication_lock_closure(character(), records, bundled)$mandatory) == 0L)
  cat("PASS: publication closure, cycles, dependency fields, subsets, drift, and missing dependencies\n")
})
