FROM alpine:3.20
RUN apk add --no-cache redsocks ca-certificates && update-ca-certificates
COPY redsocks.conf /etc/redsocks.conf
ENTRYPOINT ["redsocks"]
CMD ["-c","/etc/redsocks.conf","-p","/run/redsocks.pid"]

