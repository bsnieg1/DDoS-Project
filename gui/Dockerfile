# GUI panel for controlling the bot fleet. Runs with a mounted
# /var/run/docker.sock and manages its own pool of bot containers via docker CLI.
FROM python:3.12-alpine
# docker-cli = client to communicate with the mounted host daemon socket.
RUN apk add --no-cache docker-cli
COPY app.py /app/app.py
WORKDIR /app
EXPOSE 8090
CMD ["python", "app.py"]
