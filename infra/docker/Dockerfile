FROM python:3.10-slim
WORKDIR /app

RUN apt-get update && apt-get install -y curl git unzip && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://bun.sh/install | bash && mv /root/.bun/bin/bun /usr/local/bin/

COPY . .

ENV LOGLEVEL=debug
ENV FRONTEND_PORT=3000
ENV BACKEND_PORT=8000

RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 3000
EXPOSE 8000

CMD ["reflex", "run", "--env", "prod", "--loglevel", "debug"]