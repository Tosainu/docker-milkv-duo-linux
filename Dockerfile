FROM ubuntu:noble@sha256:278628f08d4979fb9af9ead44277dbc9c92c2465922310916ad0c46ec9999295 AS ct-ng
RUN \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    autoconf automake bison bzip2 ca-certificates curl flex g++ gawk gcc git gperf \
    help2man libc-dev libncurses5-dev libtool-bin make patch python3-dev rsync texinfo \
    unzip xz-utils && \
    rm -rf /var/lib/apt/lists/*

ARG CT_NG_COMMIT_SHA=4773bd609c0f788328d6ffc36f6cc9ea8f09a95f
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
RUN --mount=type=cache,target=/home/ubuntu/src,uid=1000,gid=1000 \
    ct-ng defconfig && CT_PREFIX=/opt/sdk ct-ng build


FROM ubuntu:noble@sha256:278628f08d4979fb9af9ead44277dbc9c92c2465922310916ad0c46ec9999295 AS base
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
RUN \
    # set ION_SIZE to 0 \
    sed -i '/\bION_SIZE\b =/s/[0-9.]\+/0/' memmap.py && \
    for ext in h conf ld; do ./mmap_conv.py --type "$ext" memmap.py "cvi_board_memmap.$ext"; done


FROM scratch AS mmap-defs
COPY --from=build-mmap-defs /work/cvi_board_memmap.* /


FROM base AS configure-linux
RUN --mount=type=tmpfs,target=/tmp \
    curl --no-progress-meter -L https://git.kernel.org/torvalds/t/linux-6.12-rc4.tar.gz -o /tmp/archive.tar.xz && \
    echo '41356c3cac4b55170506629cab54f3a0ab5a57c0fd1f0e976dbbe66a0a74cc87  /tmp/archive.tar.xz' | sha256sum -c && \
    tar xf /tmp/archive.tar.xz --strip-components=1
COPY linux/defconfig arch/riscv/configs/milkv_duo_my_defconfig
RUN \
    sed -i '/select EFI\b/d' arch/riscv/Kconfig && \
    make CROSS_COMPILE=riscv64-unknown-linux-gnu- ARCH=riscv milkv_duo_my_defconfig


FROM base AS configure-u-boot
COPY third_party/u-boot .
COPY --from=mmap-defs /cvi_board_memmap.h include/
COPY third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/u-boot/cvitek.h include/cvitek/
COPY third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/u-boot/cvi_board_init.c board/cvitek/
COPY u-boot/patches /patches
COPY u-boot/defconfig configs/milkv_duo_my_defconfig
ENV CHIP=cv1800b
ENV CVIBOARD=milkv_duo_sd
RUN \
    mkdir -p /patches && \
    find /patches -type f -print -exec sh -c 'patch -Np1 < $1' shell {} \; && \
    PATH="${PWD}/scripts/dtc:${PATH}" make CROSS_COMPILE=riscv64-unknown-linux-gnu- milkv_duo_my_defconfig


FROM configure-u-boot AS build-u-boot-dtc
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- -j$(nproc) scripts_dtc


FROM scratch AS u-boot-dtc
COPY --from=build-u-boot-dtc /work/scripts/dtc /


FROM base AS build-dtb
COPY --from=u-boot-dtc /dtc .
COPY --from=mmap-defs /cvi_board_memmap.h include/
COPY --from=configure-u-boot /work/include/dt-bindings include/dt-bindings
COPY \
    third_party/duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/dts_riscv/cv1800b_milkv_duo_sd.dts \
    third_party/duo-buildroot-sdk/build/boards/default/dts/cv180x/*.dtsi \
    third_party/duo-buildroot-sdk/build/boards/default/dts/cv180x_riscv/*.dtsi \
    .
RUN gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp -Iinclude -o - cv1800b_milkv_duo_sd.dts | ./dtc -@ -p 0x1000 -I dts -O dtb -o cv1800b_milkv_duo_sd.dtb


FROM scratch AS dtb
COPY --from=build-dtb /work/cv1800b_milkv_duo_sd.dtb /


FROM build-u-boot-dtc AS build-u-boot
COPY --from=dtb / /dtb/
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- EXT_DTB=/dtb/cv1800b_milkv_duo_sd.dtb -j$(nproc) all


FROM scratch AS u-boot
COPY --from=build-u-boot \
    /work/tools/mkimage \
    /work/u-boot.bin \
    /


FROM base AS build-opensbi
COPY third_party/opensbi .
COPY --from=dtb / /dtb/
COPY --from=u-boot /u-boot.bin /u-boot/
RUN make CROSS_COMPILE=riscv64-unknown-linux-gnu- PLATFORM=generic FW_PAYLOAD_PATH=/u-boot/u-boot.bin FW_FDT_PATH=/dtb/cv1800b_milkv_duo_sd.dtb -j$(nproc)


FROM scratch AS opensbi
COPY --from=build-opensbi /work/build/platform/generic/firmware/fw_dynamic.bin /


FROM base AS build-fsbl
COPY third_party/fsbl .
COPY --from=mmap-defs /cvi_board_memmap.h plat/cv180x/include/
COPY --from=opensbi / /opensbi
COPY --from=u-boot /u-boot.bin /u-boot/
COPY fsbl/patches /patches
RUN \
    mkdir -p /patches && \
    find /patches -type f -print -exec sh -c 'patch -Np1 < $1' shell {} \; && \
    make CROSS_COMPILE=riscv64-unknown-linux-gnu- CHIP_ARCH=cv180x BOOT_CPU=riscv DDR_CFG=ddr2_1333_x16 TEST_FROM_SPINOR1=0 PAGE_SIZE_64KB=1 FIP_COMPRESS=lzma BLCP_2ND_PATH= LOADER_2ND_PATH=/u-boot/u-boot.bin -j$(nproc)


FROM scratch AS fsbl
COPY --from=build-fsbl /work/build/cv180x/fip.bin /


FROM configure-linux AS build-linux
RUN \
    mkdir /modules && \
    make CROSS_COMPILE=riscv64-unknown-linux-gnu- ARCH=riscv -j$(nproc) Image.gz modules && \
    make CROSS_COMPILE=riscv64-unknown-linux-gnu- ARCH=riscv INSTALL_MOD_PATH=/modules modules_install


FROM scratch AS linux
COPY --from=build-linux /work/arch/riscv/boot/Image.gz /


FROM scratch AS linux-modules
COPY --from=build-linux /modules /


FROM base AS build-dtb-linux
COPY --from=u-boot-dtc /dtc .
COPY --from=configure-linux /work/arch/riscv/boot/dts/sophgo/*.dtsi /work/arch/riscv/boot/dts/sophgo/cv1800b-milkv-duo.dts .
COPY --from=configure-linux /work/include/dt-bindings include/dt-bindings
COPY append.dts .
RUN \
    cat append.dts >> cv1800b-milkv-duo.dts && \
    gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp -Iinclude -o - cv1800b-milkv-duo.dts | ./dtc -@ -p 0x1000 -I dts -O dtb -o cv1800b-milkv-duo.dtb


FROM scratch AS dtb-linux
COPY --from=build-dtb-linux /work/cv1800b-milkv-duo.dtb .


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
COPY --from=build-busybox /work/examples/udhcp/simple.script /usr/share/udhcpc/default.script
COPY --from=build-busybox \
    /opt/sdk/riscv64-unknown-linux-gnu/riscv64-unknown-linux-gnu/sysroot/etc/rpc \
    /etc/
COPY --from=build-busybox \
    /opt/sdk/riscv64-unknown-linux-gnu/riscv64-unknown-linux-gnu/sysroot/usr/bin/getconf \
    /opt/sdk/riscv64-unknown-linux-gnu/riscv64-unknown-linux-gnu/sysroot/usr/bin/getent \
    /opt/sdk/riscv64-unknown-linux-gnu/riscv64-unknown-linux-gnu/sysroot/usr/bin/ldd \
    /usr/bin/
COPY --from=build-busybox \
    /opt/sdk/riscv64-unknown-linux-gnu/riscv64-unknown-linux-gnu/sysroot/lib64/lp64d/libnss_dns.* \
    /opt/sdk/riscv64-unknown-linux-gnu/riscv64-unknown-linux-gnu/sysroot/lib64/lp64d/libnss_files.* \
    /lib64/lp64d/


FROM base AS build-ramdisk
COPY linux/strip.sh /
COPY --from=busybox / rootfs-unpopulated
COPY --from=linux-modules / rootfs-unpopulated
COPY linux/rootfs rootfs-unpopulated
RUN \
    sed -i 's!gconv;!gconv lib64/lp64 lib64/lp64d;!' /opt/sdk/riscv64-unknown-linux-gnu/bin/riscv64-unknown-linux-gnu-populate && \
    riscv64-unknown-linux-gnu-populate -s rootfs-unpopulated -d rootfs -v && \
    cd rootfs && \
    /strip.sh && \
    find . -exec touch --no-dereference -t 202410110000 {} + && \
    find . -print0 | sort --zero-terminated | cpio --create --null --reproducible --verbose --format=newc | gzip -9 > /ramdisk.cpio.gz


FROM scratch AS ramdisk
COPY --from=build-ramdisk /ramdisk.cpio.gz /


FROM base AS build-fitimage
COPY --from=linux / .
COPY --from=dtb-linux / .
COPY --from=ramdisk / .
COPY --from=u-boot /mkimage .
COPY --from=u-boot-dtc /dtc .
COPY fitimage.its .
RUN PATH="${PWD}:${PATH}" ./mkimage -f fitimage.its fitimage.bin


FROM scratch AS fitimage
COPY --from=build-fitimage /work/fitimage.bin /


FROM scratch AS all
COPY --from=fitimage / /
COPY --from=fsbl / /
