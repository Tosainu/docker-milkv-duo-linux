FROM ubuntu:noble@sha256:8a37d68f4f73ebf3d4efafbcf66379bf3728902a8038616808f04e34a9ab63ee AS ct-ng
RUN \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    autoconf automake bison bzip2 ca-certificates curl flex g++ gawk gcc git gperf \
    help2man libc-dev libncurses5-dev libtool-bin make patch python3-dev rsync texinfo \
    unzip xz-utils && \
    rm -rf /var/lib/apt/lists/*

ARG CT_NG_COMMIT_SHA=efcfd1abb6d7bc320ceed062352e0d5bebe6bf1f
RUN \
    mkdir /tmp/ct-ng && \
    cd /tmp/ct-ng && \
    git init && \
    git fetch --depth=1 https://github.com/crosstool-ng/crosstool-ng "${CT_NG_COMMIT_SHA}" && \
    git checkout FETCH_HEAD && \
    ./bootstrap && \
    ./configure && \
    make && \
    make install && \
    rm -rf /tmp/ct-ng

RUN mkdir -p /opt/sdk /work && chown -R ubuntu /opt/sdk /work
USER ubuntu
WORKDIR /work
COPY ct-ng/defconfig .
RUN ct-ng defconfig && CT_PREFIX=/opt/sdk ct-ng build


FROM ubuntu:noble@sha256:8a37d68f4f73ebf3d4efafbcf66379bf3728902a8038616808f04e34a9ab63ee
RUN \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    autoconf automake bc bison bzip2 ca-certificates curl device-tree-compiler flex g++ gawk gcc git gperf \
    help2man libc-dev libncurses5-dev libssl-dev libtool-bin make patch python3 rsync texinfo \
    unzip xz-utils && \
    rm -rf /var/lib/apt/lists/*
COPY --from=ct-ng --chown=root:root /opt/sdk /opt/sdk
ENV PATH="/opt/sdk/riscv64-unknown-linux-gnu/bin:${PATH}"
USER ubuntu
