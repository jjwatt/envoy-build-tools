#!/bin/bash -e

# Top of this file down of function defs and everything has been
# taken from common_fun.sh and ubuntu/fun.sh.
# Then, centos/fun.sh was added on top to simplify everything.
# Most function names don't even collide.
# We can see how more limited the CentOS build is/was vs the ubuntu one.

# Why?
# I'm doing this to simplify the mess so that I can hack and play
# with it. By combining, isolating and fencing this nonsense,
# I can start playing with the build containers w/o starting from
# scratch, and by using the real code, I'll know it's behaving the
# same as what's on the CI.
# So, from here, one could imagine updating the ubuntu build image
# beyond focal, updating/fixing the CentOS image, adapting the
# CentOS image to another RHEL-base or providing entirely new
# distro build images.

# Start originals
set -o pipefail

ARCH="$(uname -m)"

DEB_ARCH=amd64
case $ARCH in
    'ppc64le' )
        LLVM_DISTRO="$LLVM_DISTRO_PPC64LE"
        LLVM_SHA256SUM="$LLVM_SHA256SUM_PPC64LE"
        ;;
    'aarch64' )
        DEB_ARCH=arm64
        BAZELISK_SHA256SUM="$BAZELISK_SHA256SUM_ARM64"
        LLVM_DISTRO="$LLVM_DISTRO_ARM64"
        LLVM_SHA256SUM="$LLVM_SHA256SUM_ARM64"
        ;;
esac

download_and_check () {
    local to=$1
    local url=$2
    local sha256=$3
    echo "Download: ${url} -> ${to}"
    wget -q -O "${to}" "${url}"
    echo "${sha256}  ${to}" | sha256sum --check
}

install_llvm_bins () {
    LLVM_RELEASE="clang+llvm-${LLVM_VERSION}-${LLVM_DISTRO}"
    download_and_check "${LLVM_RELEASE}.tar.xz" "${LLVM_DOWNLOAD_PREFIX}${LLVM_VERSION}/${LLVM_RELEASE}.tar.xz" "${LLVM_SHA256SUM}"
    mkdir /opt/llvm
    tar Jxf "${LLVM_RELEASE}.tar.xz" --strip-components=1 -C /opt/llvm
    chown -R root:root /opt/llvm
    rm "./${LLVM_RELEASE}.tar.xz"
    LLVM_HOST_TARGET="$(/opt/llvm/bin/llvm-config --host-target)"
    echo "/opt/llvm/lib/${LLVM_HOST_TARGET}" > /etc/ld.so.conf.d/llvm.conf
    ldconfig
}

install_libcxx () {
    local LLVM_USE_SANITIZER=$1
    local LIBCXX_PATH=$2
    mkdir "${LIBCXX_PATH}"
    pushd "${LIBCXX_PATH}"
    cmake -GNinja \
          -DLLVM_ENABLE_PROJECTS="libcxxabi;libcxx" \
          -DLLVM_USE_LINKER=lld \
          -DLLVM_USE_SANITIZER="${LLVM_USE_SANITIZER}" \
          -DCMAKE_BUILD_TYPE=RelWithDebInfo \
          -DCMAKE_C_COMPILER=clang \
          -DCMAKE_CXX_COMPILER=clang++ \
          -DCMAKE_INSTALL_PREFIX="/opt/libcxx_${LIBCXX_PATH}" \
          "../llvm-project-llvmorg-${LLVM_VERSION}/llvm"
    ninja install-cxx install-cxxabi
    if [[ -n "$(diff --exclude=__config_site -r "/opt/libcxx_${LIBCXX_PATH}/include/c++" /opt/llvm/include/c++)" ]]; then
        echo "Different libc++ is installed";
        exit 1
    fi
    rm -rf "/opt/libcxx_${LIBCXX_PATH}/include"
    popd
}

install_san () {
    # Install sanitizer instrumented libc++, skipping for architectures other than x86_64 for now.
    if [[ "$(uname -m)" != "x86_64" ]]; then
        mkdir /opt/libcxx_msan
        mkdir /opt/libcxx_tsan
        return 0
    fi
    export PATH="/opt/llvm/bin:${PATH}"
    WORKDIR=$(mktemp -d)
    pushd "${WORKDIR}"
    wget -q -O -  "https://github.com/llvm/llvm-project/archive/llvmorg-${LLVM_VERSION}.tar.gz" | tar zx
    install_libcxx MemoryWithOrigins msan
    install_libcxx Thread tsan
    popd
}

## Build install fun
install_build_tools () {
    # bazelisk
    download_and_check \
        /usr/local/bin/bazel \
        "https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/bazelisk-linux-${DEB_ARCH}" \
        "${BAZELISK_SHA256SUM}"
    chmod +x /usr/local/bin/bazel
}

install_lcov () {
    download_and_check "lcov-${LCOV_VERSION}.tar.gz" "https://github.com/linux-test-project/lcov/releases/download/v${LCOV_VERSION}/lcov-${LCOV_VERSION}.tar.gz" \
                       "${LCOV_SHA256SUM}"
    tar zxf "lcov-${LCOV_VERSION}.tar.gz"
    make -C "lcov-${LCOV_VERSION}" install
    rm -rf "lcov-${LCOV_VERSION}" "./lcov-${LCOV_VERSION}.tar.gz"
}

install_clang_tools () {
    if [[ -z "$CLANG_TOOLS_SHA256SUM" ]]; then
        return
    fi
    # Pick `run-clang-tidy.py` from `clang-tools-extra` and place in filepath expected by Envoy CI.
    # Only required for more recent LLVM/Clang versions
    ENVOY_CLANG_TIDY_PATH=/opt/llvm/share/clang/run-clang-tidy.py
    CLANG_TOOLS_SRC="clang-tools-extra-${LLVM_VERSION}.src"
    CLANG_TOOLS_TARBALL="${CLANG_TOOLS_SRC}.tar.xz"
    download_and_check "./${CLANG_TOOLS_TARBALL}" "${LLVM_DOWNLOAD_PREFIX}${LLVM_VERSION}/${CLANG_TOOLS_TARBALL}" "$CLANG_TOOLS_SHA256SUM"
    mkdir -p /opt/llvm/share/clang/
    tar JxfO "./${CLANG_TOOLS_TARBALL}" "${CLANG_TOOLS_SRC}/clang-tidy/tool/run-clang-tidy.py" > "$ENVOY_CLANG_TIDY_PATH"
    rm "./${CLANG_TOOLS_TARBALL}"
}

install_build () {
    setup_tcpdump
    install_build_tools
    install_clang_tools
    install_lcov
    git config --global --add safe.directory /source
    mv ~/.gitconfig /etc/gitconfig
    export PATH="/opt/llvm/bin:${PATH}"
}

setup_tcpdump () {
    # Setup tcpdump for non-root.
    groupadd -r pcap
    chgrp pcap /usr/sbin/tcpdump
    chmod 750 /usr/sbin/tcpdump
    setcap cap_net_raw,cap_net_admin=eip /usr/sbin/tcpdump
}

## PPCLE64 FUN
install_ppc64le_bazel () {
    BAZEL_LATEST="$(curl https://oplab9.parqtec.unicamp.br/pub/ppc64el/bazel/ubuntu_16.04/latest/ 2>&1 \
          | sed -n 's/.*href="\([^"]*\).*/\1/p' | grep '^bazel' | head -n 1)"
    curl -fSL "https://oplab9.parqtec.unicamp.br/pub/ppc64el/bazel/ubuntu_16.04/latest/${BAZEL_LATEST}" \
         -o /usr/local/bin/bazel
    chmod +x /usr/local/bin/bazel
}

# From ubuntu/fun.sh starts here.

ubuntu_toplevel() {   
    if ! command -v lsb_release &> /dev/null; then
	apt-get -qq update -y
	apt-get -qq install -y --no-install-recommends locales
	localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
	apt-get -qq update -y
	apt-get -qq install -y --no-install-recommends lsb-release
    fi
}

# wrapping it
ubuntu_env() {
    LSB_RELEASE="$(lsb_release -cs)"
    APT_KEYS_ENV=(
	"${APT_KEY_TOOLCHAIN}")
    APT_REPOS_LLVM=(
	"https://apt.kitware.com/ubuntu/ $(lsb_release -cs) main")
    APT_KEYS_MOBILE=(
	"$APT_KEY_AZUL")
    APT_REPOS_ENV=(
	"http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu  ${LSB_RELEASE} main")
    APT_REPOS=(
	"[arch=${DEB_ARCH}] https://download.docker.com/linux/ubuntu ${LSB_RELEASE} stable"
	"http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_20.04/ /")
    COMMON_PACKAGES=(
	apt-transport-https
	ca-certificates
	g++
	git
	gnupg2
	gpg-agent
	unzip
	wget
	xz-utils)
    CI_PACKAGES=(
	aspell
	aspell-en
	jq
	libcap2-bin
	make
	patch
	tcpdump
	time
	sudo)
    LLVM_PACKAGES=(
	cmake
	cmake-data
	ninja-build
	python3)
    UBUNTU_PACKAGES=(
	automake
	bc
	byobu
	bzip2
	curl
	devscripts
	docker-buildx-plugin
	docker-ce-cli
	doxygen
	expect
	gdb
	graphviz
	libffi-dev
	libncurses-dev
	libssl-dev
	libtool
	make
	rpm
	rsync
	skopeo
	ssh-client
	strace
	tshark
	zip)
    if [[ "$ARCH" == "aarch64" ]]; then
	COMMON_PACKAGES+=(libtinfo5)
    fi    
}


# This is not currently used
# NOTE(jjwatt): Yes it is!
add_ubuntu_keys () {
    apt-get update -y
    for key in "${@}"; do
        apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys "$key"
    done
}

add_apt_key () {
    apt-get update -y
    wget -q -O - "$1" | apt-key add -
}

add_apt_k8s_key () {
    apt-get update -y
    wget -q -O - "$1" | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/devel_kubic_libcontainers_stable.gpg > /dev/null
}

add_apt_repos () {
    local repo
    apt-get update -y
    apt-get -qq install -y ca-certificates
    for repo in "${@}"; do
        echo "deb ${repo}" >> "/etc/apt/sources.list"
    done
    apt-get update -y
}

apt_install () {
    apt-get -qq update -y
    apt-get -qq install -y --no-install-recommends --no-install-suggests "${@}"
}

ensure_stdlibcc () {
    apt list libstdc++6 | grep installed | grep "$LIBSTDCXX_EXPECTED_VERSION"
}

install_base_ubuntu () {
    apt_install "${COMMON_PACKAGES[@]}"
    add_ubuntu_keys "${APT_KEYS_ENV[@]}"
    add_apt_repos "${APT_REPOS_ENV[@]}"
    apt-get -qq update
    apt-get -qq dist-upgrade -y
    ensure_stdlibcc
}

install_gn_ubuntu (){
    # Install gn tools which will be used for building wee8
    wget -q -O gntool.zip "https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-${DEB_ARCH}/+/latest"
    unzip -q gntool.zip -d gntool
    cp gntool/gn /usr/local/bin/gn
    chmod +x /usr/local/bin/gn
    rm -rf gntool*
}

mobile_install_android () {
    mkdir -p "$ANDROID_HOME"
    cd "$ANDROID_SDK_INSTALL_TARGET"
    wget -q -O android-tools.zip "${ANDROID_CLI_TOOLS}"
    unzip -q android-tools.zip
    rm android-tools.zip
    mkdir -p sdk/cmdline-tools/latest
    mv cmdline-tools/* sdk/cmdline-tools/latest
    sdkmanager="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
    echo "y" | $sdkmanager --install "ndk;${ANDROID_NDK_VERSION}" | grep -v = || true
    $sdkmanager --install "platforms;android-30" | grep -v = || true
    $sdkmanager --install "build-tools;30.0.2" | grep -v = || true
}

mobile_install_jdk () {
    # Download and install the package that adds
    # the Azul APT repository to the list of sources
    wget -q -O zulu.deb "${ZULU_INSTALL_DEB}"
    # Install the Java 11 JDK
    apt-get install -y ./zulu.deb
    apt-get update -y
    apt-get install -y zulu11-jdk
    rm ./zulu.deb
}

mobile_install () {
    add_ubuntu_keys "${APT_KEYS_MOBILE[@]}"
    mobile_install_jdk
    mobile_install_android
}

install_ubuntu () {
    if [[ "$ARCH" == "ppc64le" ]]; then
        install_ppc64le_bazel
    fi
    add_apt_key "${APT_KEY_DOCKER}"
    add_apt_k8s_key "${APT_KEY_K8S}"
    add_apt_repos "${APT_REPOS[@]}"
    apt-get -qq update
    apt-get -qq install -y --no-install-recommends "${UBUNTU_PACKAGES[@]}"
    apt-get -qq update
    apt-get -qq upgrade -y
    ensure_stdlibcc
    LLVM_HOST_TARGET="$(/opt/llvm/bin/llvm-config --host-target)"
    echo "/opt/llvm/lib/${LLVM_HOST_TARGET}" > /etc/ld.so.conf.d/llvm.conf
    ldconfig
}

install_ci () {
    ensure_stdlibcc
    apt-get -qq update -y
    apt-get -qq install -y --no-install-recommends "${CI_PACKAGES[@]}"
    install_build
}

install_llvm_ubuntu () {
    add_apt_key "${APT_KEY_KITWARE}"
    add_apt_repos "${APT_REPOS_LLVM[@]}"
    apt-get -qq update -y
    apt-get -qq install -y --no-install-recommends "${LLVM_PACKAGES[@]}"
    install_llvm_bins
    install_san
    install_gn
}


# NOTE(jjwatt): Hmm. I don't think it matters that this is defined twice.
# I concatenated common_fun.sh and ubuntu/fun.sh and centos/fun.sh
# So far, I've renamed the few functions that were different &
# I fenced some of what was at the toplevel in a function, "fromtoplevel()"
# But, yeah. bash. dynamic scope. I think it's actually even OK to sort of
# concatentate the two without renaming stuff as long as you are using it
# from the right dynamic context. Like, Example:
# If COMMON_PACKAGES is defined way at the top in the "ubuntu" version, but then
# we concatenate the "centos" version onto the bottom, the COMMON_PACKAGES variable will be
# "right" for all the top level functions up until they're re-defined!
# And, then, they're redefined and new functions are defined after that. Those will have the
# new values, which is exactly what you want, but maybe not what you're used to.

centos_env() {
    YUM_LLVM_PKGS=(
	cmake3
	ninja-build)
    # Note: rh-git218 is needed to run `git -C` in docs build process.
    # httpd24 is equired by rh-git218
    COMMON_PACKAGES=(
	devtoolset-9-binutils
	devtoolset-9-gcc
	devtoolset-9-gcc-c++
	devtoolset-9-libatomic-devel
	glibc-static
	libstdc++-static
	rh-git218
	wget)
    YUM_PKGS=(
	autoconf
	doxygen
	graphviz
	java-1.8.0-openjdk-headless
	jq
	libtool
	make
	openssl
	patch
	python27
	rsync
	sudo
	tcpdump
	unzip
	which)
}

install_base_centos () {
    localedef -c -f UTF-8 -i en_US en_US.UTF-8
    if [[ "${ARCH}" == "x86_64" ]]; then
        yum install -y centos-release-scl epel-release
    fi
    yum update -y -q
    yum install -y -q "${COMMON_PACKAGES[@]}"
    echo "/opt/rh/httpd24/root/usr/lib64" > /etc/ld.so.conf.d/httpd24.conf
    ldconfig
}

install_gn_centos () {
    # compile proper version of gn, compatible with CentOS's GLIBC version and
    # envoy wasm/v8 dependency
    # can be removed when the dependency will be updated
    git clone https://gn.googlesource.com/gn
    pushd gn
    # 45aa842fb41d79e149b46fac8ad71728856e15b9 is a hash of the version
    # before https://gn.googlesource.com/gn/+/46b572ce4ceedfe57f4f84051bd7da624c98bf01
    # as this commit expects envoy to rely on newer version of wasm/v8 with the fix
    # from https://github.com/v8/v8/commit/eac21d572e92a82f5656379bc90f8ecf1ff884fc
    # (versions 9.5.164 - 9.6.152)
    git checkout 45aa842fb41d79e149b46fac8ad71728856e15b9
    python build/gen.py
    ninja -C out
    mv -f out/gn /usr/local/bin/gn
    chmod +x /usr/local/bin/gn
    popd
}

install_llvm_centos () {
    yum update -y -q
    yum install -y -q "${YUM_LLVM_PKGS[@]}"
    ln -s /usr/bin/cmake3 /usr/bin/cmake
    # For LLVM to pick right libstdc++
    ln -s /opt/rh/devtoolset-9/root/usr/lib/gcc/x86_64-redhat-linux/9 /usr/lib/gcc/x86_64-redhat-linux
    # The installation will be skipped when building centOS
    # image on Arm64 platform since some building issues are still unsolved.
    # It will be fixed until those issues solved on Arm64 platform.
    if [[ "$ARCH" == "aarch64" ]] && grep -q -e rhel /etc/*-release ; then
        echo "Now, the CentOS image can not be built on arm64 platform!"
        mkdir /opt/libcxx_msan
        mkdir /opt/libcxx_tsan
        exit 0
    fi
    install_llvm_bins
    install_san
    install_gn
}

install_centos () {
    yum update -y -q
    yum install -y -q "${YUM_PKGS[@]}"
    # For LLVM to pick right libstdc++
    ln -s /opt/rh/devtoolset-9/root/usr/lib/gcc/x86_64-redhat-linux/9 /usr/lib/gcc/x86_64-redhat-linux
}

# Setting environments for buildx tools
config_env() {
    # Install QEMU emulators
    docker run --rm --privileged tonistiigi/binfmt --install all

    # Remove older build instance
    docker buildx rm envoy-build-tools-builder &> /dev/null || :
    docker buildx create --use --name envoy-build-tools-builder --platform "${BUILD_TOOLS_PLATFORMS}"
}
