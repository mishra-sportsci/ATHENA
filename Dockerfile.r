FROM r-base:4.4.0

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

# Install R packages
RUN R -e 'install.packages(c("plumber", "jsonlite"), repos="https://cloud.r-project.org")'

# Copy R engine
COPY plumber.R .

EXPOSE 8001

CMD ["Rscript", "plumber.R"]