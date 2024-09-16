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
        autoconf automake bc bison bzip2 ca-certificates cpio curl flex g++ gcc kmod \
        libc-dev libncurses5-dev libssl-dev libtool-bin make patch python3 xz-utils && \
    rm -rf /var/lib/apt/lists/*
COPY --from=ct-ng --chown=root:root /opt/sdk /opt/sdk
ENV PATH="/opt/sdk/riscv64-unknown-linux-gnu/bin:${PATH}"
WORKDIR /work


FROM base AS build-mmap-defs
COPY third_party/duo-buildroot-sdk/build/scripts/mmap_conv.py .
COPY third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/memmap.py .
RUN ./mmap_conv.py --type h memmap.py cvi_board_memmap.h
RUN for ext in h conf ld; do ./mmap_conv.py --type "$ext" memmap.py "cvi_board_memmap.$ext"; done


FROM scratch AS mmap-defs
COPY --from=build-mmap-defs /work/cvi_board_memmap.* /


FROM base AS build-cvipart
COPY third_party/duo-buildroot-sdk/build/tools/common/image_tool .
COPY third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/partition/partition_sd.xml .
RUN \
    mkdir include && \
    python3 mkcvipart.py partition_sd.xml include && \
    python3 mk_imgHeader.py partition_sd.xml include


FROM scratch AS cvipart
COPY --from=build-cvipart /work/include /


FROM base AS configure-u-boot
COPY third_party/duo-buildroot-sdk/u-boot-2021.10 .
COPY --from=mmap-defs /cvi_board_memmap.h include/
COPY --from=cvipart /* include/
COPY third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/u-boot/cvitek.h include/cvitek/
COPY third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/u-boot/cvi_board_init.c board/cvitek/
COPY \
    third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/dts_riscv/cv1800b_milkv_duo_sd.dts \
    third_party/duo-buildroot-sdk/build/boards/default/dts/cv180x/*.dtsi \
    third_party/duo-buildroot-sdk/build/boards/default/dts/cv180x_riscv/*.dtsi \
    arch/riscv/dts/
COPY u-boot/patches /patches
COPY u-boot/defconfig configs/milkv_duo_my_defconfig
ENV CHIP=cv1800b
ENV CVIBOARD=milkv_duo_sd
RUN \
    find /patches -type f -print -exec sh -c 'patch -Np1 < $1' shell {} \; && \
    PATH="${PWD}/scripts/dtc:${PATH}" make CROSS_COMPILE=riscv64-unknown-linux-gnu- milkv_duo_my_defconfig


FROM configure-u-boot AS build-u-boot
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- -j$(nproc) all


FROM scratch AS u-boot
COPY --from=build-u-boot \
    /work/arch/riscv/dts/cv1800b_milkv_duo_sd.dtb \
    /work/scripts/dtc \
    /work/tools/mkimage \
    /work/u-boot.bin \
    /


FROM base AS build-opensbi
COPY third_party/duo-buildroot-sdk/opensbi .
COPY --from=u-boot /u-boot.bin /cv1800b_milkv_duo_sd.dtb /u-boot/
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- PLATFORM=generic FW_PAYLOAD_PATH=/u-boot/u-boot.bin FW_FDT_PATH=/u-boot/cv1800b_milkv_duo_sd.dtb -j$(nproc)


FROM scratch AS opensbi
COPY --from=build-opensbi /work/build/platform/generic/firmware/fw_dynamic.bin /


FROM base AS build-fsbl
COPY third_party/duo-buildroot-sdk/fsbl .
COPY --from=mmap-defs /cvi_board_memmap.h plat/cv180x/include/
COPY --from=opensbi / /opensbi
COPY --from=u-boot /u-boot.bin /u-boot/
RUN \
    sed -i 's!^\(MONITOR_PATH\)\b.\+$!\1 = /opensbi/fw_dynamic.bin!' make_helpers/fip.mk && \
    make CROSS_COMPILE=riscv64-unknown-linux-gnu- CHIP_ARCH=cv180x BOOT_CPU=riscv DDR_CFG=ddr2_1333_x16 TEST_FROM_SPINOR1=0 PAGE_SIZE_64KB=1 BLCP_2ND_PATH= LOADER_2ND_PATH=/u-boot/u-boot.bin -j$(nproc)


FROM scratch AS fsbl
COPY --from=build-fsbl /work/build/cv180x/fip.bin /


FROM base AS configure-linux
COPY third_party/duo-buildroot-sdk/linux_5.10 .
COPY third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/linux/cvitek_cv1800b_milkv_duo_sd_defconfig arch/riscv/configs
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- ARCH=riscv cvitek_cv1800b_milkv_duo_sd_defconfig


FROM configure-linux AS build-linux
RUN \
    mkdir /modules && \
    make CROSS_COMPILE=riscv64-unknown-linux-gnu- ARCH=riscv -j$(nproc) Image modules && \
    make CROSS_COMPILE=riscv64-unknown-linux-gnu- ARCH=riscv INSTALL_MOD_PATH=/modules modules_install


FROM scratch AS linux
COPY --from=build-linux /work/arch/riscv/boot/Image /


FROM scratch AS linux-modules
COPY --from=build-linux /modules /


FROM base AS configure-busybox
RUN --mount=type=tmpfs,target=/tmp \
    curl --no-progress-meter -L https://git.busybox.net/busybox/snapshot/busybox-1_36_1.tar.bz2 -o /tmp/archive.tar.bz2 && \
    echo 'cbc37db19734db3d57c324bf8ed0fa993401a0194ff07599c404e336b2fbdc67  /tmp/archive.tar.bz2' | sha256sum -c && \
    tar xf /tmp/archive.tar.bz2 --strip-components=1
COPY busybox/config .config
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- oldconfig

FROM configure-busybox AS build-busybox
RUN \
    make ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- -j$(nproc) && \
    make ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- install


FROM scratch AS busybox
COPY --from=build-busybox /work/_install /


FROM base AS build-ramdisk
COPY --from=busybox / .
COPY --from=linux-modules / .
COPY linux/rootfs .
RUN find . -print0 | cpio --null --create --verbose --format=newc | gzip -9 > ramdisk.cpio.gz


FROM scratch AS ramdisk
COPY --from=build-ramdisk /work/ramdisk.cpio.gz /


FROM base AS build-dtb-linux
COPY --from=u-boot /dtc .
COPY --from=mmap-defs /cvi_board_memmap.h include/
COPY --from=configure-linux /work/include/dt-bindings include/dt-bindings
COPY \
    third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/dts_riscv/cv1800b_milkv_duo_sd.dts \
    third_party/duo-buildroot-sdk/build/boards/default/dts/cv180x/*.dtsi \
    third_party/duo-buildroot-sdk/build/boards/default/dts/cv180x_riscv/*.dtsi \
    .
COPY append.dts .
RUN \
    cat append.dts >> cv1800b_milkv_duo_sd.dts && \
    gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp -Iinclude -o - cv1800b_milkv_duo_sd.dts | ./dtc -@ -p 0x1000 -I dts -O dtb -o cv1800b_milkv_duo_sd.dtb


FROM scratch AS dtb-linux
COPY --from=build-dtb-linux /work/cv1800b_milkv_duo_sd.dtb /


FROM base AS build-fitimage
COPY --from=dtb-linux / .
COPY --from=linux / .
COPY --from=ramdisk / .
COPY --from=u-boot /mkimage /dtc .
COPY fitimage.its .
RUN PATH="${PWD}:${PATH}" ./mkimage -f fitimage.its fitimage.bin


FROM scratch AS fitimage
COPY --from=build-fitimage /work/fitimage.bin /


FROM scratch AS all
COPY --from=fitimage / /
COPY --from=fsbl / /
