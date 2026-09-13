FROM rocker/r-ver:4.6.1

LABEL org.opencontainers.image.source="https://github.com/ckrusemd/money-printer-go-brrr"

ENV DEBIAN_FRONTEND=noninteractive \
    RENV_CONFIG_REPOS_OVERRIDE=https://cloud.r-project.org \
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
        libtiff-dev \
        libudunits2-dev \
        libwebp-dev \
        libxml2-dev \
        libzmq3-dev \
        cmake \
        pkg-config \
        pandoc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /project
COPY renv.lock renv.lock
COPY renv/settings.json renv/settings.json
COPY renv/activate.R renv/activate.R

RUN Rscript --vanilla -e 'install.packages("renv", repos = "https://cloud.r-project.org"); renv::restore(lockfile = "renv.lock", prompt = FALSE)'

CMD ["Rscript", "--vanilla"]
