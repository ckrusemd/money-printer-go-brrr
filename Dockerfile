FROM rocker/r-ver:4.3.3

LABEL org.opencontainers.image.source="https://github.com/ckrusemd/money-printer-go-brrr"

ENV DEBIAN_FRONTEND=noninteractive \
    RENV_CONFIG_REPOS_OVERRIDE=https://cloud.r-project.org \
    RENV_PATHS_CACHE=/renv/cache

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        libcurl4-openssl-dev \
        libglpk-dev \
        libssl-dev \
        libxml2-dev \
        pkg-config \
        pandoc \
        pandoc-citeproc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /project
COPY renv.lock renv.lock
COPY renv/settings.json renv/settings.json
COPY renv/activate.R renv/activate.R
COPY .Rprofile .Rprofile

RUN Rscript --vanilla -e 'install.packages("renv", repos = "https://cloud.r-project.org"); renv::restore(lockfile = "renv.lock", prompt = FALSE)'

CMD ["Rscript", "--vanilla"]
