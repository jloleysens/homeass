FROM alpine:3.12 AS build
WORKDIR /build
RUN apk --update add bash curl
RUN curl -L 'https://github.com/fsaris/home-assistant-zonneplan-one/archive/refs/tags/2024.10.1.tar.gz' -o zonneplan_one.tar.gz
RUN mkdir zonneplan_one
RUN tar xzf zonneplan_one.tar.gz -C zonneplan_one
RUN mv ./zonneplan_one/home-assistant-zonneplan-one-2024.10.1/custom_components .

FROM ghcr.io/home-assistant/home-assistant:stable
COPY --from=build /build/custom_components /config/custom_components
