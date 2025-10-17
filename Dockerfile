# ===============================
# Stage 1: Build FFmpeg with arch-specific optimizations
# ===============================
FROM python:slim-bullseye AS build-ffmpeg
WORKDIR /tmp
ENV DEBIAN_FRONTEND=noninteractive
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV LD_LIBRARY_PATH=/usr/local/lib

# Detect architecture
ARG TARGETPLATFORM
ARG BUILDPLATFORM
RUN echo "Building on $BUILDPLATFORM for $TARGETPLATFORM"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake build-essential cmake git pkg-config texinfo \
    yasm nasm libtool libssl-dev ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

# ============ fdk-aac ============
RUN git clone --depth 1 https://github.com/mstorsjo/fdk-aac.git && \
    cd fdk-aac && autoreconf -fiv && \
    ./configure --prefix=/usr/local --disable-shared CFLAGS="-fPIC" && \
    make -j$(nproc) && make install

# ============ LAME ============
RUN git clone --depth 1 https://github.com/rbrito/lame.git && \
    cd lame && ./configure --prefix=/usr/local --disable-shared --enable-nasm && \
    make -j$(nproc) && make install

# ============ Opus ============
RUN git clone --depth 1 https://github.com/xiph/opus.git && \
    cd opus && ./autogen.sh && ./configure --prefix=/usr/local --disable-shared && \
    make -j$(nproc) && make install

# ============ NVENC headers (only for amd64) ============
RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git && \
        cd nv-codec-headers && make && make install; \
    fi

# ============ x264 ============
RUN git clone --depth 1 https://code.videolan.org/videolan/x264.git && \
    cd x264 && ./configure --enable-static --disable-shared --prefix=/usr/local && \
    make -j$(nproc) && make install

# ============ x265 ============
RUN git clone --depth 1 https://bitbucket.org/multicoreware/x265_git /tmp/x265 && \
    cd /tmp/x265/build/linux && \
    cmake -G "Unix Makefiles" \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DENABLE_SHARED=OFF \
      -DENABLE_PIC=ON \
      ../../source && \
    make -j$(nproc) && make install && \
    \
    # Create or fix pkg-config file
    mkdir -p /usr/local/lib/pkgconfig && \
    cat > /usr/local/lib/pkgconfig/x265.pc <<'EOF'
prefix=/usr/local
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: 3.5
Libs: -L${libdir} -lx265 -lstdc++ -lpthread -lm
Libs.private: -ldl -lstdc++
Cflags: -I${includedir}
EOF

RUN pkg-config --exists x265 && echo "✅ x265 pkg-config OK" || echo "⚠️ x265 pkg-config missing"

# ============ FFmpeg (multi-arch with NVENC / NEON) ============
RUN git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git /tmp/ffmpeg && \
    cd /tmp/ffmpeg && \
    echo ">>> Building FFmpeg for $TARGETPLATFORM" && \
    pkg-config --list-all | grep x265 || true && \
    \
    FFMPEG_OPTS=" \
      --prefix=/usr/local \
      --pkg-config-flags=--static \
      --extra-cflags=-I/usr/local/include \
      --extra-ldflags=-L/usr/local/lib \
      --extra-libs=\"-lpthread -lm\" \
      --enable-gpl --enable-nonfree \
      --enable-libx264 --enable-libx265 \
      --enable-libmp3lame --enable-libopus --enable-libfdk-aac \
      --disable-shared --enable-static" && \
    \
    if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        FFMPEG_OPTS="$FFMPEG_OPTS --enable-nvenc --enable-nvdec"; \
    elif [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        FFMPEG_OPTS="$FFMPEG_OPTS --enable-neon --enable-asm --enable-v4l2-request --enable-libdrm"; \
    elif [ "$TARGETPLATFORM" = "linux/arm/v7" ]; then \
        FFMPEG_OPTS="$FFMPEG_OPTS --enable-neon --enable-asm --cpu=cortex-a72"; \
    fi && \
    \
    eval ./configure $FFMPEG_OPTS && \
    make -j$(nproc) && \
    make install && \
    strip /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
