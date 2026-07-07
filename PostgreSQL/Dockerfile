FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir requests psycopg2-binary

COPY toss_chart_collect.py .

ENV DB_HOST=172.17.0.4
ENV DB_PORT=5432

CMD ["python", "toss_chart_collect.py"]
