FROM python:3.12.16-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /srv

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY log_doctor/ log_doctor/

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin logdoctor
USER 10001

ENTRYPOINT ["python", "-m", "log_doctor.main"]
