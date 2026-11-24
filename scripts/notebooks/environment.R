# Fail before calculations if the project kernel has a different library.
local({
  lock <- jsonlite::read_json("renv.lock", simplifyVector = FALSE)
  stopifnot(as.character(getRversion()) == lock$R$Version)
  for (package in names(lock$Packages)) {
    actual <- utils::packageVersion(package)
    if (actual != package_version(lock$Packages[[package]]$Version)) {
      stop("Locked version mismatch: ", package)
    }
  }
  stopifnot(requireNamespace("IRkernel"), requireNamespace("IRdisplay"),
            requireNamespace("plotly"), requireNamespace("htmlwidgets"),
            requireNamespace("dstcollect"))
  description <- read.dcf("packages/dstcollect/DESCRIPTION")
  stopifnot(utils::packageVersion("dstcollect") == package_version(description[1L,"Version"]))
})
