FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    r-base \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

RUN R -e "install.packages(c('plumber','jsonlite'), repos='https://cloud.r-project.org')"

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN mkdir -p backups

EXPOSE 8000 8001

CMD ["/bin/bash", "athena.sh"]
