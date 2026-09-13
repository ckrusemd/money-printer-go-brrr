FROM rocker/r-ver:4.3.3

LABEL org.opencontainers.image.source="https://github.com/ckrusemd/money-printer-go-brrr"

ENV DEBIAN_FRONTEND=noninteractive \
    RENV_CONFIG_REPOS_OVERRIDE=https://packagemanager.posit.co/cran/2026-09-08 \
    RENV_PATHS_CACHE=/renv/cache \
    QUARTO_VERSION=1.7.32

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
        libudunits2-dev \
        libwebp-dev \
        libxml2-dev \
        libzmq3-dev \
        cmake \
        curl \
        pkg-config \
        pandoc \
        pandoc-citeproc \
    && rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --retry 3 \
      "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb" \
      --output /tmp/quarto.deb \
    && apt-get update \
    && apt-get install --yes --no-install-recommends /tmp/quarto.deb \
    && rm -f /tmp/quarto.deb \
    && rm -rf /var/lib/apt/lists/* \
    && quarto --version

WORKDIR /project
COPY renv.lock renv.lock
COPY renv/settings.json renv/settings.json
COPY renv/activate.R renv/activate.R

RUN Rscript --vanilla -e 'install.packages("renv", repos = "https://cloud.r-project.org"); renv::restore(lockfile = "renv.lock", prompt = FALSE)'

# dkstat is distributed through rOpenGov's R-universe rather than the lockfile.
RUN Rscript --vanilla -e 'install.packages("dkstat", repos = c(ropengov = "https://ropengov.r-universe.dev", CRAN = "https://cloud.r-project.org"))'

CMD ["Rscript", "--vanilla"]
