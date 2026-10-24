FROM rocker/r-ver:4.6.1@sha256:bafb3b9a72791eeeb810f0bc0472e74c7f4939b20b46c96cb7ebc6838b6a25ef

LABEL org.opencontainers.image.source="https://github.com/ckrusemd/money-printer-go-brrr"

ARG QUARTO_VERSION=1.10.19
ARG QUARTO_SHA256=7f0c4769e7f0e55f50d922f44b18db5118fb388d2b8fd27291fe1f8beafb43eb
ARG PUBLICATION_CONTEXT=development
LABEL org.money-printer.context=$PUBLICATION_CONTEXT
ENV NOTEBOOK_IMAGE_CONTEXT=$PUBLICATION_CONTEXT

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
        python3-venv \
        python3-dev \
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
        "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb" \
        --output /tmp/quarto.deb \
    && echo "${QUARTO_SHA256}  /tmp/quarto.deb" | sha256sum --check --strict \
    && apt-get install --yes --no-install-recommends /tmp/quarto.deb \
    && rm -f /tmp/quarto.deb \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /project
COPY renv.lock renv.lock
COPY renv/settings.json renv/settings.json
COPY renv/activate.R renv/activate.R

# Keep the library outside /project: Actions checkout replaces that directory.
# Bootstrap the same renv version as the lock, rather than the latest release.
# Ignore upstream optional Remotes (dkstat suggests geodk/dawaR). Explicit
# GitHub records remain pinned and all strong dependencies remain in the lock.
RUN mkdir -p /opt/publication-library \
    && Rscript --vanilla -e 'Sys.setenv(RENV_CONFIG_INSTALL_REMOTES = "FALSE"); install.packages("renv", repos = Sys.getenv("RENV_CONFIG_REPOS_OVERRIDE"), lib = Sys.getenv("R_LIBS_USER")); stopifnot(utils::packageVersion("renv") == "1.3.1"); renv::restore(lockfile = "renv.lock", library = Sys.getenv("R_LIBS_USER"), prompt = FALSE)' \
    && Rscript --vanilla -e 'lock <- renv::lockfile_read("renv.lock"); for (p in names(lock$Packages)) stopifnot(utils::packageVersion(p) == package_version(lock$Packages[[p]]$Version)); stopifnot(requireNamespace("bookdown", quietly = TRUE), requireNamespace("xml2", quietly = TRUE), requireNamespace("fredr", quietly = TRUE), requireNamespace("dkstat", quietly = TRUE))'

# Internal sources are installed separately from the unchanged external lock.
COPY packages/dstcollect /project/packages/dstcollect
COPY scripts/internal_packages.py /project/scripts/internal_packages.py
RUN python3 scripts/internal_packages.py install

# One Python runtime and one registered R kernel for editors and CI.
COPY scripts/notebooks/requirements.lock /tmp/notebook-requirements.lock
RUN python3 -m venv /opt/notebook-python \
    && /opt/notebook-python/bin/pip install --no-cache-dir --no-deps -r /tmp/notebook-requirements.lock \
    && /opt/notebook-python/bin/pip check
ENV PATH=/opt/notebook-python/bin:/opt/quarto/bin:$PATH \
    QUARTO_PYTHON=/opt/notebook-python/bin/python \
    RSTUDIO_PANDOC=/opt/quarto/bin/tools/x86_64 \
    JUPYTER_DATA_DIR=/usr/local/share/jupyter
RUN Rscript --vanilla -e 'IRkernel::installspec(user = FALSE, name = "money-r", displayname = "Money Printer R 4.6.1")' \
    && python3 -c 'import json; from pathlib import Path; p = Path("/usr/local/share/jupyter/kernels/money-r/kernel.json"); spec = json.loads(p.read_text()); spec["argv"].insert(1, "--vanilla"); p.write_text(json.dumps(spec))' \
    && chmod 755 /usr/local/share/jupyter \
    && useradd --create-home --non-unique --uid 1000 notebook \
    && mkdir -p /project/.cache \
    && chown -R notebook:notebook /project
EXPOSE 8000
CMD ["python3", "-m", "scripts.notebooks.book", "build"]
