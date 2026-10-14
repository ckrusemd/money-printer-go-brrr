# Refresh both locks from one dated CRAN snapshot, retaining research-only roots.
# Run explicitly with the target R and renv installed; never during rendering.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L || !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", args)) {
  stop("Usage: Rscript --vanilla scripts/refresh_r_locks.R YYYY-MM-DD")
}
repository <- paste0("https://packagemanager.posit.co/cran/", args)
old <- renv::lockfile_read("renv.lock")
old_publication <- renv::lockfile_read("renv/publication.lock")
omitted <- setdiff(names(old$Packages), names(old_publication$Packages))
approved <- c("IRdisplay", "IRkernel", "pacman", "pbdZMQ", "repr", "uuid")
stopifnot(setequal(omitted, approved))
db <- available.packages(repos = repository, type = "source")
standard <- rownames(installed.packages(priority = c("base", "recommended")))
records <- old$Packages
queue <- names(records)
visited <- character()
fields <- c("Depends", "Imports", "LinkingTo", "Suggests", "Enhances")
while (length(queue)) {
  package <- queue[[1L]]
  queue <- queue[-1L]
  if (package %in% visited) next
  visited <- c(visited, package)
  if (package %in% rownames(db)) {
    entry <- as.list(db[package, ])
    entry <- entry[!vapply(entry, function(x) is.na(x) || !nzchar(x), logical(1))]
    # available.packages' Repository is a download path, not the lock's name.
    entry$Source <- "Repository"
    entry$Repository <- "CRAN"
    for (field in intersect(fields, names(entry))) {
      entry[[field]] <- trimws(strsplit(entry[[field]], ",")[[1L]])
    }
    records[[package]] <- entry
  } else if (is.null(records[[package]]) || records[[package]]$Source == "Repository") {
    stop("No compatible package in snapshot: ", package)
  }
  entry <- records[[package]]
  deps <- unlist(entry[intersect(c("Depends", "Imports", "LinkingTo"), names(entry))])
  deps <- trimws(sub("\\s*\\(.*$", "", deps))
  # Preserve explicitly locked recommended packages such as Matrix, while
  # other recommended/base dependencies come with this pinned R distribution.
  deps <- setdiff(deps, c("R", setdiff(standard, names(records))))
  queue <- unique(c(queue, setdiff(deps, visited)))
}
lock <- list(R = list(Version = as.character(getRversion()),
                     Repositories = c(CRAN = repository)),
             Packages = records[sort(names(records))])
renv::lockfile_write(lock, "renv.lock")
lock$Packages[omitted] <- NULL
renv::lockfile_write(lock, "renv/publication.lock")
cat("R", as.character(getRversion()), ":", length(records), "research /",
    length(lock$Packages), "publication packages from", repository, "\n")
