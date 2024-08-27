# Base image
FROM ubuntu:20.04 AS base

# Download VOICEVOX Core shared object
FROM base AS download-core-env
ARG DEBIAN_FRONTEND=noninteractive
ARG GITHUB_TOKEN

WORKDIR /work

RUN apt-get update && \
    apt-get install -y \
        wget \
        unzip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ARG TARGETPLATFORM
ARG USE_GPU=false
ARG VOICEVOX_CORE_VERSION=0.15.4

RUN if [ "${USE_GPU}" = "true" ]; then \
        VOICEVOX_CORE_ASSET_ASSET_PROCESSING="gpu"; \
    else \
        VOICEVOX_CORE_ASSET_ASSET_PROCESSING="cpu"; \
    fi && \
    if [ "${TARGETPLATFORM}" = "linux/amd64" ]; then \
        VOICEVOX_CORE_ASSET_TARGETARCH="x64"; \
    else \
        VOICEVOX_CORE_ASSET_TARGETARCH="arm64"; \
    fi && \
    VOICEVOX_CORE_ASSET_PREFIX="voicevox_core-linux-${VOICEVOX_CORE_ASSET_TARGETARCH}-${VOICEVOX_CORE_ASSET_ASSET_PROCESSING}" && \
    VOICEVOX_CORE_ASSET_NAME=${VOICEVOX_CORE_ASSET_PREFIX}-${VOICEVOX_CORE_VERSION} && \
    wget --no-check-certificate --header="Authorization: token ${GITHUB_TOKEN}" -nv -O "./${VOICEVOX_CORE_ASSET_NAME}.zip" "https://github.com/VOICEVOX/voicevox_core/releases/download/${VOICEVOX_CORE_VERSION}/${VOICEVOX_CORE_ASSET_NAME}.zip" && \
    unzip "./${VOICEVOX_CORE_ASSET_NAME}.zip" && \
    mkdir -p /opt/voicevox_core && \
    mv ${VOICEVOX_CORE_ASSET_NAME}/* /opt/voicevox_core/ && \
    rm -rf ${VOICEVOX_CORE_ASSET_NAME} && \
    rm "./${VOICEVOX_CORE_ASSET_NAME}.zip" && \
    echo "/opt/voicevox_core" > /etc/ld.so.conf.d/voicevox_core.conf && \
    ldconfig


# Download ONNX Runtime
FROM base AS download-onnxruntime-env
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /work

RUN set -e \
    && set -u \
    && set -x \
    && apt-get update \
    && apt-get install -y \
        wget \
        tar \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETPLATFORM
ARG USE_GPU=false
ARG ONNXRUNTIME_VERSION=1.13.1

RUN if [ "${USE_GPU}" = "true" ]; then \
        ONNXRUNTIME_PROCESSING="gpu-"; \
    else \
        ONNXRUNTIME_PROCESSING=""; \
    fi && \
    if [ "${TARGETPLATFORM}" = "linux/amd64" ]; then \
        ONNXRUNTIME_TARGETARCH=x64; \
    else \
        ONNXRUNTIME_TARGETARCH=aarch64; \
    fi && \
    ONNXRUNTIME_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/onnxruntime-linux-${ONNXRUNTIME_TARGETARCH}-${ONNXRUNTIME_PROCESSING}${ONNXRUNTIME_VERSION}.tgz" && \
    wget -nv --show-progress -c -O "./onnxruntime.tgz" "${ONNXRUNTIME_URL}" && \
    mkdir -p /opt/onnxruntime && \
    tar xf "./onnxruntime.tgz" -C "/opt/onnxruntime" --strip-components 1 && \
    rm ./onnxruntime.tgz && \
    echo "/opt/onnxruntime/lib" > /etc/ld.so.conf.d/onnxruntime.conf && \
    ldconfig


FROM base AS compile-python-env

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        build-essential \
        libssl-dev \
        zlib1g-dev \
        libbz2-dev \
        libreadline-dev \
        libsqlite3-dev \
        curl \
        libncursesw5-dev \
        xz-utils \
        tk-dev \
        libxml2-dev \
        libxmlsec1-dev \
        libffi-dev \
        liblzma-dev \
        git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ARG PYTHON_VERSION=3.11.3
ARG PYENV_VERSION=v2.3.17
ARG PYENV_ROOT=/tmp/.pyenv
ARG PYBUILD_ROOT=/tmp/python-build

RUN for i in 1 2 3 4 5; do \
        git clone -b "${PYENV_VERSION}" https://github.com/pyenv/pyenv.git "$PYENV_ROOT" && break || sleep 15; \
    done && \
    PREFIX="$PYBUILD_ROOT" "$PYENV_ROOT"/plugins/python-build/install.sh && \
    for i in 1 2 3 4 5; do \
        PYTHON_BUILD_MIRROR_URL="https://npm.taobao.org/mirrors/python" \
        PYTHON_BUILD_CURL_OPTS="--connect-timeout 60 --max-time 1200" \
        "$PYBUILD_ROOT/bin/python-build" -v "$PYTHON_VERSION" /opt/python && break || sleep 15; \
    done && \
    rm -rf "$PYBUILD_ROOT" "$PYENV_ROOT"


# Runtime
FROM base AS runtime-env
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /opt/voicevox_engine

# ca-certificates: pyopenjtalk dictionary download
# build-essential: pyopenjtalk local build
# libsndfile1: soundfile shared object for arm64
# ref: https://github.com/VOICEVOX/voicevox_engine/issues/770
RUN apt-get update && \
    apt-get install -y \
        git \
        wget \
        cmake \
        ca-certificates \
        build-essential \
        gosu \
        libsndfile1 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    # Create a general user
    useradd --create-home user

# Copy python env
COPY --from=compile-python-env /opt/python /opt/python

# Install Python dependencies
ADD ./requirements.txt /tmp/
RUN for i in 1 2 3 4 5; do \
        gosu user /opt/python/bin/pip3 install --default-timeout=100 --retries 3 -i https://pypi.tuna.tsinghua.edu.cn/simple -r /tmp/requirements.txt && break || sleep 15; \
    done

# Copy VOICEVOX Core release
COPY --from=download-core-env /opt/voicevox_core /opt/voicevox_core

# Copy ONNX Runtime
COPY --from=download-onnxruntime-env /opt/onnxruntime /opt/onnxruntime

# Add local files
ADD ./voicevox_engine /opt/voicevox_engine/voicevox_engine
ADD ./docs /opt/voicevox_engine/docs
ADD ./run.py ./presets.yaml ./engine_manifest.json /opt/voicevox_engine/
ADD ./resources /opt/voicevox_engine/resources
ADD ./tools/generate_licenses.py /opt/voicevox_engine/tools/
ADD ./tools/licenses /opt/voicevox_engine/tools/licenses
ADD ./tools/generate_filemap.py /opt/voicevox_engine/tools/

# Replace version
ARG VOICEVOX_ENGINE_VERSION=latest
RUN sed -i "s/__version__ = \"latest\"/__version__ = \"${VOICEVOX_ENGINE_VERSION}\"/" /opt/voicevox_engine/voicevox_engine/__init__.py
RUN sed -i "s/\"version\": \"999\\.999\\.999\"/\"version\": \"${VOICEVOX_ENGINE_VERSION}\"/" /opt/voicevox_engine/engine_manifest.json

# Generate licenses.json
ADD ./requirements.txt /tmp/
ADD ./requirements-dev.txt /tmp/
RUN cd /opt/voicevox_engine && \
    export PATH="/home/user/.local/bin:${PATH:-}" && \
    gosu user /opt/python/bin/pip3 install -r /tmp/requirements.txt && \
    gosu user /opt/python/bin/pip3 install "$(grep pip-licenses /tmp/requirements-dev.txt | cut -f 1 -d ';')" && \
    gosu user /opt/python/bin/python3 tools/generate_licenses.py > /opt/voicevox_engine/resources/engine_manifest_assets/dependency_licenses.json && \
    cp /opt/voicevox_engine/resources/engine_manifest_assets/dependency_licenses.json /opt/voicevox_engine/licenses.json

# Generate filemap.json
RUN /opt/python/bin/python3 /opt/voicevox_engine/tools/generate_filemap.py --target_dir /opt/voicevox_engine/resources/character_info

# Keep this layer separated to use layer cache on download failed in local build
RUN for i in $(seq 5); do \
        EXIT_CODE=0; \
        gosu user /opt/python/bin/python3 -c "import pyopenjtalk; pyopenjtalk._lazy_init()" || EXIT_CODE=$?; \
        if [ "$EXIT_CODE" = "0" ]; then \
            break; \
        fi; \
        sleep 5; \
    done && \
    if [ "$EXIT_CODE" != "0" ]; then \
        exit "$EXIT_CODE"; \
    fi

# Download Resource
ARG VOICEVOX_RESOURCE_VERSION=0.20.0
RUN wget -nv --show-progress -c -O "/opt/voicevox_engine/README.md" "https://raw.githubusercontent.com/VOICEVOX/voicevox_resource/${VOICEVOX_RESOURCE_VERSION}/engine/README.md"

# Create container start shell
RUN echo '#!/bin/bash\n\
set -eux\n\
\n\
# Display README for engine\n\
cat /opt/voicevox_engine/README.md > /dev/stderr\n\
\n\
exec "$@"' > /entrypoint.sh && \
    chmod 775 /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh"  ]
CMD [ "gosu", "user", "/opt/python/bin/python3", "./run.py", "--voicelib_dir", "/opt/voicevox_core/", "--runtime_dir", "/opt/onnxruntime/lib", "--host", "0.0.0.0" ]

# Enable use_gpu
FROM runtime-env AS runtime-nvidia-env
CMD [ "gosu", "user", "/opt/python/bin/python3", "./run.py", "--use_gpu", "--voicelib_dir", "/opt/voicevox_core/", "--runtime_dir", "/opt/onnxruntime/lib", "--host", "0.0.0.0" ]
