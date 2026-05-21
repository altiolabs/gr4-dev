# syntax=docker/dockerfile:1.7

ARG GR4_DEV_BUILDER_IMAGE=gr4-dev/ubuntu-24.04-clang-20:latest
ARG GNURADIO4_SDK_IMAGE=gnuradio4-sdk
ARG RUNTIME_BASE_IMAGE=ubuntu:24.04

FROM ${GR4_DEV_BUILDER_IMAGE} AS base

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PKG_CONFIG=pkg-config

WORKDIR /opt

FROM base AS gnuradio4-builder

ARG SOURCE_MODE=local
ARG GNURADIO4_SOURCE=
ARG GNURADIO4_REPO=https://github.com/gnuradio/gnuradio4.git
ARG GNURADIO4_REF=main
ARG GR_SPLIT_BLOCK_INSTANTIATIONS=OFF
ARG GR4_USE_LIBCXX=OFF

COPY src/gnuradio4/ /opt/gnuradio4-local/

RUN set -eux; \
    source_mode="${GNURADIO4_SOURCE:-${SOURCE_MODE}}"; \
    case "${source_mode}" in \
      local) \
        mv /opt/gnuradio4-local /opt/gnuradio4; \
        ;; \
      git) \
        rm -rf /opt/gnuradio4-local; \
        git clone --depth 1 --branch "${GNURADIO4_REF}" "${GNURADIO4_REPO}" /opt/gnuradio4 || \
          (git clone "${GNURADIO4_REPO}" /opt/gnuradio4 && cd /opt/gnuradio4 && git checkout "${GNURADIO4_REF}"); \
        ;; \
      *) \
        echo "Unsupported GNU Radio 4 source mode: ${source_mode}; use local or git." >&2; \
        exit 1; \
        ;; \
    esac

WORKDIR /opt/gnuradio4

RUN --mount=type=cache,target=/root/.cache/ccache \
    cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=RelWithAssert \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DGR_ENABLE_BLOCK_REGISTRY=ON \
      -DWARNINGS_AS_ERRORS=OFF \
      -DTIMETRACE=OFF \
      -DADDRESS_SANITIZER=OFF \
      -DUB_SANITIZER=OFF \
      -DTHREAD_SANITIZER=OFF \
      -DBUILD_SHARED_LIBS=ON \
      -DGR_SPLIT_BLOCK_INSTANTIATIONS="${GR_SPLIT_BLOCK_INSTANTIATIONS}" \
      -DGR4_USE_LIBCXX="${GR4_USE_LIBCXX}" \
      -DENABLE_TESTING=OFF \
      -DENABLE_EXAMPLES=OFF \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build

FROM gnuradio4-builder AS gnuradio4-sdk

ARG OCI_SOURCE
ARG OCI_URL
ARG OCI_REVISION
ARG OCI_VERSION
ARG SOURCE_MODE=local
ARG GR4_USE_LIBCXX=OFF
ARG GR4_INCUBATOR_REPO=https://github.com/gnuradio/gr4-incubator.git
ARG GR4_INCUBATOR_REF=main

COPY src/gr4-incubator/ /opt/gr4-incubator-local/

RUN set -eux; \
    case "${SOURCE_MODE}" in \
      local) \
        mv /opt/gr4-incubator-local /opt/gr4-incubator; \
        ;; \
      git) \
        rm -rf /opt/gr4-incubator-local; \
        git clone --depth 1 --branch "${GR4_INCUBATOR_REF}" "${GR4_INCUBATOR_REPO}" /opt/gr4-incubator || \
          (git clone "${GR4_INCUBATOR_REPO}" /opt/gr4-incubator && cd /opt/gr4-incubator && git checkout "${GR4_INCUBATOR_REF}"); \
        ;; \
      *) \
        echo "Unsupported SOURCE_MODE=${SOURCE_MODE}; use local or git." >&2; \
        exit 1; \
        ;; \
    esac

RUN --mount=type=cache,target=/root/.cache/ccache \
    set -eux; \
    libcxx_args=""; \
    if [ "${GR4_USE_LIBCXX}" = "ON" ]; then \
      libcxx_args="-DCMAKE_CXX_FLAGS=-stdlib=libc++ -DCMAKE_EXE_LINKER_FLAGS=-stdlib=libc++ -DCMAKE_SHARED_LINKER_FLAGS=-stdlib=libc++"; \
    fi; \
    cd /opt/gr4-incubator && \
    cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DENABLE_TESTING=OFF \
      -DENABLE_EXAMPLES=OFF \
      -DENABLE_GUI_EXAMPLES=OFF \
      -DENABLE_PLUGINS=ON \
      ${libcxx_args} && \
    cmake --build build -j"$(nproc)" && \
    cmake --install build

RUN ldconfig

RUN set -eux; \
    if [ "${GR4_USE_LIBCXX}" = "ON" ]; then \
      install -m 0644 /opt/gnuradio4/build/_deps/cpp-httplib-src/httplib.h /usr/local/include/httplib.h; \
      install -d /usr/local/lib/pkgconfig; \
      { \
        printf '%s\n' 'prefix=/usr/local'; \
        printf '%s\n' 'includedir=${prefix}/include'; \
        printf '%s\n' ''; \
        printf '%s\n' 'Name: cpp-httplib'; \
        printf '%s\n' 'Description: C++ HTTP/HTTPS server and client library'; \
        printf '%s\n' 'Version: 0.18.1'; \
        printf '%s\n' 'Cflags: -I${includedir} -DCPPHTTPLIB_OPENSSL_SUPPORT -DCPPHTTPLIB_ZLIB_SUPPORT -DCPPHTTPLIB_BROTLI_SUPPORT'; \
        printf '%s\n' 'Libs:'; \
      } > /usr/local/lib/pkgconfig/cpp-httplib.pc; \
    fi

LABEL org.opencontainers.image.title="gnuradio4-sdk" \
      org.opencontainers.image.description="GNU Radio 4 base SDK image for building compatible downstream plugins" \
      org.opencontainers.image.source="${OCI_SOURCE}" \
      org.opencontainers.image.url="${OCI_URL}" \
      org.opencontainers.image.revision="${OCI_REVISION}" \
      org.opencontainers.image.version="${OCI_VERSION}"

ENV GR4CP_GNURADIO4_PREFIX=/usr/local \
    GNURADIO4_PLUGIN_DIRECTORIES=/usr/local/lib/gnuradio-4/plugins:/usr/local/lib

FROM ${GNURADIO4_SDK_IMAGE} AS toolchain

RUN ldconfig

ENV GR4CP_GNURADIO4_PREFIX=/usr/local \
    GNURADIO4_PLUGIN_DIRECTORIES=/usr/local/lib/gnuradio-4/plugins:/usr/local/lib

FROM toolchain AS builder

ARG GR4CP_INSTALL_PREFIX=/opt/gr4-control-plane
ARG SOURCE_MODE=local
ARG GR4_USE_LIBCXX=OFF
ARG CONTROL_PLANE_REPO=https://github.com/altiolabs/gr4-control-plane
ARG CONTROL_PLANE_REF=main

COPY src/gr4-control-plane/ /workspaces/gr4-control-plane-local/

RUN set -eux; \
    case "${SOURCE_MODE}" in \
      local) \
        mv /workspaces/gr4-control-plane-local /workspaces/gr4-control-plane; \
        ;; \
      git) \
        rm -rf /workspaces/gr4-control-plane-local; \
        git clone --depth 1 --branch "${CONTROL_PLANE_REF}" "${CONTROL_PLANE_REPO}" /workspaces/gr4-control-plane || \
          (git clone "${CONTROL_PLANE_REPO}" /workspaces/gr4-control-plane && cd /workspaces/gr4-control-plane && git checkout "${CONTROL_PLANE_REF}"); \
        ;; \
      *) \
        echo "Unsupported SOURCE_MODE=${SOURCE_MODE}; use local or git." >&2; \
        exit 1; \
        ;; \
    esac

WORKDIR /workspaces/gr4-control-plane

RUN --mount=type=cache,target=/root/.cache/ccache \
    set -eux; \
    libcxx_args=""; \
    if [ "${GR4_USE_LIBCXX}" = "ON" ]; then \
      libcxx_args="-DCMAKE_CXX_FLAGS=-stdlib=libc++ -DCMAKE_EXE_LINKER_FLAGS=-stdlib=libc++ -DCMAKE_SHARED_LINKER_FLAGS=-stdlib=libc++"; \
    fi; \
    cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${GR4CP_INSTALL_PREFIX}" \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DGR4CP_GNURADIO4_PREFIX=/usr/local \
      -DGR4CP_SUPPRESS_IMPORTED_WERROR=ON \
      ${libcxx_args} \
    && cmake --build build --target gr4cp_server gr4cp_cli_exec -j"$(nproc)" \
    && cmake --install build

FROM toolchain AS studio-blocks-builder

ARG GR4CP_INSTALL_PREFIX=/opt/gr4-control-plane
ARG STUDIO_BLOCKS_CACHE_BUST=0
ARG SOURCE_MODE=local
ARG GR4_USE_LIBCXX=OFF
ARG STUDIO_REPO=https://github.com/altiolabs/gr4-studio
ARG STUDIO_REF=main

COPY src/gr4-studio/ /workspaces/gr4-studio-local/

RUN set -eux; \
    case "${SOURCE_MODE}" in \
      local) \
        mv /workspaces/gr4-studio-local /workspaces/gr4-studio; \
        ;; \
      git) \
        rm -rf /workspaces/gr4-studio-local; \
        git clone --depth 1 --branch "${STUDIO_REF}" "${STUDIO_REPO}" /workspaces/gr4-studio || \
          (git clone "${STUDIO_REPO}" /workspaces/gr4-studio && cd /workspaces/gr4-studio && git checkout "${STUDIO_REF}"); \
        ;; \
      *) \
        echo "Unsupported SOURCE_MODE=${SOURCE_MODE}; use local or git." >&2; \
        exit 1; \
        ;; \
    esac

WORKDIR /workspaces/gr4-studio/blocks

RUN --mount=type=cache,target=/root/.cache/ccache \
    set -eux; \
    libcxx_args=""; \
    if [ "${GR4_USE_LIBCXX}" = "ON" ]; then \
      libcxx_args="-DCMAKE_CXX_FLAGS=-stdlib=libc++ -DCMAKE_EXE_LINKER_FLAGS=-stdlib=libc++ -DCMAKE_SHARED_LINKER_FLAGS=-stdlib=libc++"; \
    fi; \
    printf 'studio blocks cache bust: %s\n' "${STUDIO_BLOCKS_CACHE_BUST}" && \
    cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${GR4CP_INSTALL_PREFIX}" \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      ${libcxx_args} \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build

FROM toolchain AS sdk

ARG OCI_SOURCE
ARG OCI_URL
ARG OCI_REVISION
ARG OCI_VERSION

COPY --from=builder /opt/gr4-control-plane /opt/gr4-control-plane
COPY --from=studio-blocks-builder /opt/gr4-control-plane /opt/gr4-control-plane

LABEL org.opencontainers.image.title="gr4-control-plane-sdk" \
      org.opencontainers.image.description="GR4 control-plane SDK image for building compatible downstream plugins" \
      org.opencontainers.image.source="${OCI_SOURCE}" \
      org.opencontainers.image.url="${OCI_URL}" \
      org.opencontainers.image.revision="${OCI_REVISION}" \
      org.opencontainers.image.version="${OCI_VERSION}"

ENV PATH="/opt/gr4-control-plane/bin:${PATH}" \
    GNURADIO4_PLUGIN_DIRECTORIES="/usr/local/lib/gnuradio-4/plugins:/usr/local/lib:/opt/gr4-control-plane/lib"

WORKDIR /workspace
CMD ["/bin/bash"]

FROM ${RUNTIME_BASE_IMAGE} AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PKG_CONFIG=pkg-config

RUN set -eux; \
    if [ -f /etc/os-release ]; then . /etc/os-release; else ID=unknown; fi; \
    case "${ID}" in \
      ubuntu|debian) \
        apt-get update -q; \
        apt-get install --no-install-recommends -qy \
          ca-certificates \
          curl \
          locales \
          libbrotli1 \
          libcurl4 \
          libjack-jackd2-0 \
          libportaudio2 \
          libssl3 \
          libsoapysdr0.8 \
          libzmq5 \
          soapysdr-module-all; \
        apt-get install --no-install-recommends -qy librtaudio7 || \
          apt-get install --no-install-recommends -qy librtaudio6 || \
          apt-get install --no-install-recommends -qy librtaudio5; \
        rm -rf /var/lib/apt/lists/*; \
        ;; \
      fedora) \
        dnf -y install \
          ca-certificates \
          brotli \
          curl \
          libcurl \
          jack-audio-connection-kit \
          portaudio \
          rtaudio \
          openssl-libs \
          SoapySDR \
          zeromq; \
        dnf clean all; \
        ;; \
      *) \
        echo "Unsupported runtime base distro: ${ID}" >&2; \
        exit 1; \
        ;; \
    esac

COPY --from=toolchain /usr/local /usr/local
COPY --from=toolchain /usr/lib /usr/lib

ARG OCI_SOURCE
ARG OCI_URL
ARG OCI_REVISION
ARG OCI_VERSION

COPY --from=builder /opt/gr4-control-plane /opt/gr4-control-plane
COPY --from=studio-blocks-builder /opt/gr4-control-plane /opt/gr4-control-plane

RUN ldconfig

LABEL org.opencontainers.image.title="gr4-control-plane-runtime" \
      org.opencontainers.image.description="Runtime image for gr4-control-plane with Studio-compatible blocks" \
      org.opencontainers.image.source="${OCI_SOURCE}" \
      org.opencontainers.image.url="${OCI_URL}" \
      org.opencontainers.image.revision="${OCI_REVISION}" \
      org.opencontainers.image.version="${OCI_VERSION}"

ENV PATH="/opt/gr4-control-plane/bin:${PATH}" \
    GNURADIO4_PLUGIN_DIRECTORIES="/usr/local/lib/gnuradio-4/plugins:/usr/local/lib:/opt/gr4-control-plane/lib"

WORKDIR /opt/gr4-control-plane
EXPOSE 8080
ENTRYPOINT ["/opt/gr4-control-plane/bin/gr4cp_server"]

FROM node:20-alpine AS studio-builder

ARG SOURCE_MODE=local
ARG STUDIO_REPO=https://github.com/altiolabs/gr4-studio
ARG STUDIO_REF=main

RUN apk add --no-cache git

COPY src/gr4-studio/ /workspaces/gr4-studio-local/

RUN set -eux; \
    case "${SOURCE_MODE}" in \
      local) \
        mv /workspaces/gr4-studio-local /workspaces/gr4-studio; \
        ;; \
      git) \
        rm -rf /workspaces/gr4-studio-local; \
        git clone --depth 1 --branch "${STUDIO_REF}" "${STUDIO_REPO}" /workspaces/gr4-studio || \
          (git clone "${STUDIO_REPO}" /workspaces/gr4-studio && cd /workspaces/gr4-studio && git checkout "${STUDIO_REF}"); \
        ;; \
      *) \
        echo "Unsupported SOURCE_MODE=${SOURCE_MODE}; use local or git." >&2; \
        exit 1; \
        ;; \
    esac

WORKDIR /workspaces/gr4-studio
RUN npm ci
RUN npm run build:web

FROM nginx:1.27-alpine AS studio

COPY images/nginx/gr4-studio.conf /etc/nginx/conf.d/default.conf
COPY --from=studio-builder /workspaces/gr4-studio/dist /usr/share/nginx/html
EXPOSE 80
