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


FROM ubuntu:noble@sha256:8a37d68f4f73ebf3d4efafbcf66379bf3728902a8038616808f04e34a9ab63ee AS base
RUN \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    autoconf automake bc bison bzip2 ca-certificates curl device-tree-compiler flex g++ gawk gcc git gperf \
    help2man libc-dev libncurses5-dev libssl-dev libtool-bin make patch python3 rsync texinfo \
    unzip xz-utils && \
    rm -rf /var/lib/apt/lists/*
COPY --from=ct-ng --chown=root:root /opt/sdk /opt/sdk
ENV PATH="/opt/sdk/riscv64-unknown-linux-gnu/bin:${PATH}"
WORKDIR /work


FROM base AS build-mmap-defs
COPY duo-buildroot-sdk/build/scripts/mmap_conv.py .
COPY duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/memmap.py .
RUN ./mmap_conv.py --type h memmap.py cvi_board_memmap.h
RUN for ext in h conf ld; do ./mmap_conv.py --type "$ext" memmap.py "cvi_board_memmap.$ext"; done


FROM scratch AS mmap-defs
COPY --from=build-mmap-defs /work/cvi_board_memmap.* .


FROM base AS build-cvipart
COPY duo-buildroot-sdk/build/tools/common/image_tool .
COPY duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/partition/partition_sd.xml .
RUN \
    mkdir include && \
    python3 mkcvipart.py partition_sd.xml include && \
    python3 mk_imgHeader.py partition_sd.xml include


FROM scratch AS cvipart
COPY --from=build-cvipart /work/include .


FROM base AS configure-u-boot
COPY duo-buildroot-sdk/u-boot-2021.10 .
COPY --from=mmap-defs /cvi_board_memmap.h include/
COPY --from=cvipart /* include/
COPY duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/u-boot/cvitek.h include/cvitek/
COPY duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/u-boot/cvi_board_init.c board/cvitek/
COPY duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/u-boot/cvitek_cv1800b_milkv_duo_sd_defconfig configs/
COPY \
    duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/dts_riscv/cv1800b_milkv_duo_sd.dts \
    duo-buildroot-sdk/build/boards/default/dts/cv180x/*.dtsi \
    duo-buildroot-sdk/build/boards/default/dts/cv180x_riscv/*.dtsi \
    arch/riscv/dts/
ARG CHIP=cv1800b
ARG CVIBOARD=milkv_duo_sd
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- cvitek_cv1800b_milkv_duo_sd_defconfig


FROM configure-u-boot AS build-u-boot
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- -j$(nproc) all


FROM scratch AS u-boot
COPY --from=build-u-boot /work/u-boot.bin /u-boot-raw.bin
COPY --from=build-u-boot /work/arch/riscv/dts/cv1800b_milkv_duo_sd.dtb .


FROM base AS build-opensbi
COPY duo-buildroot-sdk/opensbi .
COPY --from=u-boot / /u-boot
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- PLATFORM=generic FW_PAYLOAD_PATH=/u-boot/u-boot-raw.bin FW_FDT_PATH=/u-boot/cv1800b_milkv_duo_sd.dtb -j$(nproc)
