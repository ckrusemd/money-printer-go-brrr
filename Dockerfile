FROM rocker/r-ver:4.3.3@sha256:732d15020af326da9e919c07f70ca32bf5d3e409220af32e0a4b6d0a89437309

LABEL org.opencontainers.image.source="https://github.com/ckrusemd/money-printer-go-brrr"

ARG PANDOC_VERSION=3.1.11.1
ARG PANDOC_SHA256=ab0ac0aa1c3f9b23243d14e43023e06cbce51a52420aba17d27bd0d9c28f73ac

ENV DEBIAN_FRONTEND=noninteractive \
    RENV_CONFIG_REPOS_OVERRIDE=https://packagemanager.posit.co/cran/2026-09-08 \
    RENV_PATHS_CACHE=/renv/cache

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
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
COPY renv.lock renv.lock
COPY renv/settings.json renv/settings.json
COPY renv/activate.R renv/activate.R

RUN Rscript --vanilla -e 'install.packages("renv", repos = "https://cloud.r-project.org"); renv::restore(lockfile = "renv.lock", prompt = FALSE)'

CMD ["Rscript", "--vanilla"]
