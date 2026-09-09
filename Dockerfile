FROM rocker/r-ver:4.3.3

LABEL org.opencontainers.image.source="https://github.com/ckrusemd/money-printer-go-brrr"

ENV DEBIAN_FRONTEND=noninteractive \
    RENV_CONFIG_REPOS_OVERRIDE=https://packagemanager.posit.co/cran/2025-08-25 \
    RENV_PATHS_CACHE=/renv/cache

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        libcurl4-openssl-dev \
        libfontconfig1-dev \
        libfreetype6-dev \
        libfribidi-dev \
        libglpk-dev \
        libharfbuzz-dev \
        libjpeg-dev \
        libpng-dev \
        libssl-dev \
        libtiff5-dev \
        libwebp-dev \
        libxml2-dev \
        cmake \
        pkg-config \
        pandoc \
        pandoc-citeproc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /project
COPY renv.lock renv.lock
COPY renv/settings.json renv/settings.json
COPY renv/activate.R renv/activate.R

RUN Rscript --vanilla -e 'install.packages("renv", repos = "https://cloud.r-project.org"); renv::restore(lockfile = "renv.lock", prompt = FALSE)'

CMD ["Rscript", "--vanilla"]
