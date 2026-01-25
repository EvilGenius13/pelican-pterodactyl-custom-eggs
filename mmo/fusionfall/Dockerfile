FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y \
    git cmake make clang libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --recurse-submodules https://github.com/OpenFusionProject/OpenFusion.git .

RUN mkdir build && cd build \
    && cmake .. \
    && make

# Find the binary and move it to a known spot
RUN find /build -type f -name "fusion" -exec cp {} /build/fusion-server \;

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -d /home/container -m container
WORKDIR /home/container

RUN mkdir -p /opt/openfusion

COPY --from=builder /build/fusion-server /opt/openfusion/fusion
COPY --from=builder /build/config.ini /opt/openfusion/config.ini
COPY --from=builder /build/tdata /opt/openfusion/tdata
COPY --from=builder /build/sql /opt/openfusion/sql
COPY --from=builder /build/res /opt/openfusion/res

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER container
ENV USER=container HOME=/home/container

CMD ["/entrypoint.sh"]
