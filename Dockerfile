FROM rocker/r-ver:4.6.1@sha256:4e6e6696ff54a86625c7f80046478e67014a2184e942b85eeff43db7b992d93e

LABEL org.opencontainers.image.source="https://github.com/ckrusemd/money-printer-go-brrr"

ARG PANDOC_VERSION=3.1.11.1
ARG PANDOC_SHA256=ab0ac0aa1c3f9b23243d14e43023e06cbce51a52420aba17d27bd0d9c28f73ac

ENV DEBIAN_FRONTEND=noninteractive \
    RENV_CONFIG_REPOS_OVERRIDE=https://packagemanager.posit.co/cran/2026-10-14 \
    RENV_PATHS_CACHE=/renv/cache \
    R_LIBS_USER=/opt/publication-library

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        time \
        python3 \
        git \
        libgit2-dev \
        libx11-dev \
        libcurl4-openssl-dev \
        libgdal-dev \
        libgeos-dev \
        libfontconfig1-dev \
        libfreetype6-dev \
        libfribidi-dev \
        libglpk-dev \
        libharfbuzz-dev \
        libjpeg-dev \
        libpng-dev \
        libssl-dev \
        libtiff-dev \
        libudunits2-dev \
        libwebp-dev \
        libxml2-dev \
        libproj-dev \
        libsqlite3-dev \
        libzmq3-dev \
        cmake \
        gfortran \
        build-essential \
        pkg-config \
    && curl --fail --location --silent --show-error \
        "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-1-amd64.deb" \
        --output /tmp/pandoc.deb \
    && echo "${PANDOC_SHA256}  /tmp/pandoc.deb" | sha256sum --check --strict \
    && apt-get install --yes --no-install-recommends /tmp/pandoc.deb \
    && rm -f /tmp/pandoc.deb \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /project
COPY renv/publication.lock renv/publication.lock
COPY renv/settings.json renv/settings.json
COPY renv/activate.R renv/activate.R

# Keep the library outside /project: Actions checkout replaces that directory.
# Bootstrap the same renv version as the lock, rather than the latest release.
# Ignore upstream optional Remotes (dkstat suggests geodk/dawaR). Explicit
# GitHub records remain pinned and all strong dependencies remain in the lock.
RUN mkdir -p /opt/publication-library \
    && Rscript --vanilla -e 'Sys.setenv(RENV_CONFIG_INSTALL_REMOTES = "FALSE"); install.packages("renv", repos = Sys.getenv("RENV_CONFIG_REPOS_OVERRIDE"), lib = Sys.getenv("R_LIBS_USER")); stopifnot(utils::packageVersion("renv") == "1.3.1"); renv::restore(lockfile = "renv/publication.lock", library = Sys.getenv("R_LIBS_USER"), prompt = FALSE)' \
    && Rscript --vanilla -e 'lock <- renv::lockfile_read("renv/publication.lock"); for (p in names(lock$Packages)) stopifnot(utils::packageVersion(p) == package_version(lock$Packages[[p]]$Version)); stopifnot(requireNamespace("bookdown", quietly = TRUE), requireNamespace("xml2", quietly = TRUE), requireNamespace("fredr", quietly = TRUE), requireNamespace("dkstat", quietly = TRUE))'

CMD ["Rscript", "--vanilla"]
