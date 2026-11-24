# Read-only static closure evidence. No lock rewriting, restore, or network calls.
# Static exclusions still need live-output and isolated replay proof before pruning.
publication_lock_closure <- function(roots, records,
                                     bundled = rownames(utils::installed.packages(
                                       priority = c("base", "recommended")))) {
  seen <- character()
  pending <- sort(unique(roots))
  while (length(pending)) {
    package <- pending[[1L]]
    pending <- pending[-1L]
    if (package %in% c("R", seen)) next
    seen <- c(seen, package)
    # Traverse a locked recommended package even when R also bundles it.
    if (!package %in% names(records)) {
      if (!package %in% bundled) stop("Missing lock dependency: ", package)
      next
    }
    dependencies <- as.character(unlist(
      records[[package]][c("Depends", "Imports", "LinkingTo")], use.names = FALSE))
    dependencies <- unlist(strsplit(dependencies, ",", fixed = TRUE), use.names = FALSE)
    dependencies <- trimws(sub("\\s*\\(.*$", "", dependencies))
    pending <- unique(c(pending, setdiff(dependencies[nzchar(dependencies)], c("R", seen))))
  }
  list(roots = sort(unique(setdiff(roots, "R"))),
       mandatory = sort(intersect(seen, names(records))),
       bundled = sort(setdiff(seen, names(records))),
       candidates = sort(setdiff(names(records), seen)))
}

audit_publication_closure <- function(root, publication, roots,
                                      bundled = rownames(utils::installed.packages(
                                        priority = c("base", "recommended")))) {
  if (!identical(root$R, publication$R)) stop("Publication R configuration differs from root lock")
  extra <- setdiff(names(publication$Packages), names(root$Packages))
  if (length(extra)) stop("Publication records absent from root: ", paste(extra, collapse = ", "))
  changed <- names(publication$Packages)[!vapply(names(publication$Packages), function(package) {
    identical(publication$Packages[[package]], root$Packages[[package]])
  }, logical(1))]
  if (length(changed)) stop("Publication records differ from root: ", paste(changed, collapse = ", "))
  closure <- publication_lock_closure(roots, root$Packages, bundled)
  missing <- setdiff(closure$mandatory, names(publication$Packages))
  if (length(missing)) stop("Publication lock omits mandatory dependencies: ", paste(missing, collapse = ", "))
  closure$retained <- sort(names(publication$Packages))
  closure$preserves_all <- setequal(closure$retained, names(root$Packages))
  closure
}

check_publication_closure <- function(root_file = "renv.lock",
                                      publication_file = "renv/publication.lock") {
  source("scripts/check_publication_dependencies.R", local = TRUE)
  # The internal package is fingerprinted/installed from this checkout; its
  # Imports are already included by publication_dependencies().
  roots <- setdiff(publication_dependencies(),"dstcollect")
  root <- renv::lockfile_read(root_file)
  publication <- renv::lockfile_read(publication_file)
  closure <- audit_publication_closure(root, publication, roots)
  cat("Declared publication roots:", length(closure$roots), "\n")
  cat("Mandatory locked records (Depends/Imports/LinkingTo):", length(closure$mandatory), "\n")
  cat("Retained publication records:", length(closure$retained), "\n")
  cat("All root records retained:", closure$preserves_all, "\n")
  cat("Static exclusion candidates:", paste(closure$candidates, collapse = ", "), "\n")
  cat("Bundled R dependencies outside lock:", paste(closure$bundled, collapse = ", "), "\n")
  cat("Not pruning proof: optional/dynamic dependencies need successful live output and isolated replay.\n")
  invisible(closure)
}

if (sys.nframe() == 0L) check_publication_closure()
