# Panel GUI do sterowania flota botow. Uruchamia sie z zamontowanym
# /var/run/docker.sock i zarzadza wlasna pula kontenerow-botow przez docker CLI.
FROM python:3.12-alpine
# docker-cli = klient do rozmowy z zamontowanym socketem demona hosta.
RUN apk add --no-cache docker-cli
COPY app.py /app/app.py
WORKDIR /app
EXPOSE 8090
CMD ["python", "app.py"]
