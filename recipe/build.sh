#!/bin/bash
# *****************************************************************
# (C) Copyright IBM Corp. 2023. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *****************************************************************

set -ex

source open-ce-common-utils.sh

if [[ $ppc_arch == "p10" ]]
then
    if [[ -z "${GCC_11_HOME}" ]];
    then
        echo "Please set GCC_11_HOME to the install path of gcc-toolset-11"
        exit 1
    else
        export PATH=$GCC_11_HOME/bin:$PATH
        export CC=$GCC_11_HOME/bin/gcc
        export CXX=$GCC_11_HOME/bin/g++
        export GCC=$CC
        export GXX=$CXX
        export AR=${GCC_11_HOME}/bin/ar
        export LD=${GCC_11_HOME}/bin/ld
        export NM=${GCC_11_HOME}/bin/nm
        export OBJCOPY=${GCC_11_HOME}/bin/objcopy
        export OBJDUMP=${GCC_11_HOME}/bin/objdump
        export RANLIB=${GCC_11_HOME}/bin/ranlib
        export STRIP=${GCC_11_HOME}/bin/strip
        export READELF=${GCC_11_HOME}/bin/readelf
        export HOST=powerpc64le-conda_cos7-linux-gnu
        export BAZEL_LINKLIBS=-l%:libstdc++.a

        # Removing these libs so that jaxlib libraries link against libstdc++.so present on
        # the system provided by gcc-toolset-11
        rm ${PREFIX}/lib/libstdc++.so*
        rm ${BUILD_PREFIX}/lib/libstdc++.so*
        export LDFLAGS="-Wl,-O2 -Wl,-S -fuse-ld=gold -Wl,-no-as-needed -Wl,-z,now -B/opt/rh/gcc-toolset-11/root/usr/bin -lrt -L${GCC_11_HOME}/lib -L${PREFIX}/lib"

        export CXXFLAGS="${CXXFLAGS} -mcpu=power9 -mtune=power10 -U_FORTIFY_SOURCE -fstack-protector -Wall -Wunused-but-set-parameter -Wno-free-nonheap-object -fno-omit-frame-pointer -g0 -O2 '-D_FORTIFY_SOURCE=1' -DNDEBUG -ffunction-sections -fdata-sections '-std=c++0x' -DAUTOLOAD_DYNAMIC_KERNELS"
        export CPPFLAGS="${CPPFLAGS} -mcpu=power9 -mtune=power10"
        export CFLAGS="${CFLAGS} -mcpu=power9 -mtune=power10" 

        export CONDA_BUILD_SYSROOT=""
    fi
else
    if [[ ! -f $BUILD_PREFIX/bin/ar ]]; then
        ln -s $AR $BUILD_PREFIX/bin/ar
    fi
fi

if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="${LDFLAGS} -lz -framework CoreFoundation -Xlinker -undefined -Xlinker dynamic_lookup"
fi
export CFLAGS="${CFLAGS} -DNDEBUG"
export CXXFLAGS="${CXXFLAGS} -I${PREFIX}/include"
source gen-bazel-toolchain

cat >> .bazelrc <<EOF
build --crosstool_top=//bazel_toolchain:toolchain
build --logging=6
build --verbose_failures
build --toolchain_resolution_debug
build --define=PREFIX=${PREFIX}
build --define=PROTOBUF_INCLUDE_PATH=${PREFIX}/include
build --local_cpu_resources=${CPU_COUNT}"
build --copt="-fplt"
build --cxxopt="-fplt"
build --action_env GCC_HOST_COMPILER_PATH="${CC}"
EOF

if [[ "${ARCH}" == 's390x' ]]; then
echo "Building with more compiler flag for ${ARCH}"
# extra compiler flag added for further optimization
cat >> .bazelrc << EOF
build:opt --copt=-O3
build:opt --copt=-funroll-loops
EOF
else
cat >> .bazelrc << EOF
build --linkopt="-fuse-ld=gold"
EOF
fi

if [[ "${target_platform}" == "osx-arm64" ]]; then
  echo "build --cpu=${TARGET_CPU}" >> .bazelrc
fi

# For debugging
# CUSTOM_BAZEL_OPTIONS="${CUSTOM_BAZEL_OPTIONS} --bazel_options=--subcommands"

if [[ "${target_platform}" == "osx-64" ]]; then
  # Tensorflow doesn't cope yet with an explicit architecture (darwin_x86_64) on osx-64 yet.
  TARGET_CPU=darwin
fi

if [[ "${cuda_compiler_version:-None}" != "None" ]]; then
    if [[ ${cuda_compiler_version} == 10.* ]]; then
        export TF_CUDA_COMPUTE_CAPABILITIES=sm_35,sm_50,sm_60,sm_62,sm_70,sm_72,sm_75,compute_75
    elif [[ ${cuda_compiler_version} == 11.0* ]]; then
        export TF_CUDA_COMPUTE_CAPABILITIES=sm_35,sm_50,sm_60,sm_62,sm_70,sm_72,sm_75,sm_80,compute_80
    elif [[ ${cuda_compiler_version} == 11.1 ]]; then
        export TF_CUDA_COMPUTE_CAPABILITIES=sm_35,sm_50,sm_60,sm_62,sm_70,sm_72,sm_75,sm_80,sm_86,compute_86
    elif [[ ${cuda_compiler_version} == 11.2 || ${cuda_compiler_version} == 11.8 || ${cuda_compiler_version} == 12.2 ]]; then
        export TF_CUDA_COMPUTE_CAPABILITIES="${cuda_levels_details}"
    else
        echo "unsupported cuda version."
        exit 1
    fi

    export TF_CUDA_VERSION="${cuda_compiler_version}"
    export TF_CUDNN_VERSION="8.9.6"
    export TF_CUDA_PATHS="${CUDA_HOME},${PREFIX},/usr/include"
    export TF_NEED_CUDA=1
    export TF_NCCL_VERSION=$(pkg-config nccl --modversion | grep -Po '\d+\.\d+')
    export CUDNN_INSTALL_PATH="${PREFIX}"
    export NCCL_INSTALL_PATH="${PREFIX}"
    CUDA_ARGS="--enable_cuda \
               --enable_nccl \
               --cuda_path=${CUDA_HOME} \
               --cudnn_path=${PREFIX}   \
               --cuda_compute_capabilities=$TF_CUDA_COMPUTE_CAPABILITIES \
               --cuda_version=$TF_CUDA_VERSION \
               --cudnn_version=$TF_CUDNN_VERSION"
fi

# Force static linkage with protobuf to avoid definition collisions,
# see https://github.com/conda-forge/jaxlib-feedstock/issues/89
#
# Thus: don't add com_google_protobuf here.
# FIXME: Current global abseil pin is too old for jaxlib, readd com_google_absl once we are on a newer version.

if [[ "${target_platform}" == "osx-arm64" ]]; then
  ${PYTHON} build/build.py --target_cpu_features default --enable_mkl_dnn --target_cpu ${TARGET_CPU}
else
  ${PYTHON} build/build.py --target_cpu_features default --enable_mkl_dnn ${CUDA_ARGS:-} --bazel_startup_options="--bazelrc=$SRC_DIR/.jax_configure.bazelrc"
fi

# Clean up to speedup postprocessing
pushd build
PID=$(bazel info server_pid)
echo "PID: $PID"
cleanup_bazel $PID
popd

pushd $SP_DIR
# pip doesn't want to install cleanly in all cases, so we use the fact that we can unzip it.
unzip $SRC_DIR/dist/jaxlib-*.whl
popd
