#!/bin/bash

header() {
    TS=`date +"%Y-%m-%dT%H:%M:%S%:z"`
    echo "${TS} +--------------------------------------------+"
    echo "${TS} | $*"
    echo "${TS} +--------------------------------------------+"
    echo
}

msg() {
    echo `date +"%Y-%m-%dT%H:%M:%S%:z"` $*
}

update_fresh_container() {
    header "Upgrading and installing packages"
    sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update -y >/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install dotnet-sdk-8.0 make \
        gcc g++ autoconf automake m4 libtool -y >/dev/null

    if [ $? -ne 0 ]; then
        exit 32
    fi
    sudo apt autoclean

    msg "Initializing LXD environment"
    sudo lxd init --preseed </tmp/lxd-preseed.yaml

    msg "Make sure we have lxd authority"
    sudo usermod -G lxd -a ubuntu
}

setup_dotnet_sdk() {
    SDK_VERSION=`dotnet --version`
    msg "Using SDK - ${SDK_VERSION}"

    # fix ownership
    sudo chown ubuntu:ubuntu /home/ubuntu/.bashrc

    sudo chmod +x /etc/rc.local
    sudo systemctl start rc-local

    return 0
}

patch_runner() {
    header "Cloning repo and Patching runner"
    cd /tmp
    git clone -q ${RUNNERREPO}
    cd runner
    git checkout $(git describe --tags $(git rev-list --tags --max-count=1)) -b build 
    git apply /home/ubuntu/runner-sdk-8.patch
    sed -i'' -e 's/"version": "8[^"]*"/"version": "'${SDK_VERSION}'"/' src/global.json
    sed -i'' -e 's/"version": "8[^"]*"/"version": "'${SDK_VERSION}'"/' .devcontainer/devcontainer.json
    sed -i'' -e 's/DOTNETSDK_VERSION="8[^"]*"/DOTNETSDK_VERSION="'${SDK_VERSION}'"/' src/dev.sh
    return $?
}

build_runner() {
    export DOTNET_NUGET_SIGNATURE_VERIFICATION=false
    header "Building runner binary"
    cd src

    msg "dev layout"
    ./dev.sh layout

    if [ $? -eq 0 ]; then
        msg "dev package"
        ./dev.sh package 

        if [ $? -eq 0 ]; then
            msg "Finished building runner binary"

            msg "Running tests"
            ./dev.sh test
        fi
    fi

    return $?
}

install_runner() {
    header "Installing runner"
    sudo mkdir -p /opt/runner 
    sudo tar -xf /tmp/runner/_package/*.tar.gz -C /opt/runner
    if [ $? -eq 0 ]; then
        sudo chown ubuntu:ubuntu -R /opt/runner
        /opt/runner/config.sh --version
    fi
    return $?
}

cleanup() {
    rm -rf /home/ubuntu/build-image.sh /home/ubuntu/runner-sdk-8.patch \
           /tmp/runner /tmp/preseed-yaml
}

run() {
    update_fresh_container
    setup_dotnet_sdk
    RC=$?
    if [ ${RC} -eq 0 ]; then
        patch_runner
        RC=$?
        if [ ${RC} -eq 0 ]; then
            build_runner
            RC=$?
            if [ ${RC} -eq 0 ]; then
                install_runner
                RC=$?
            fi
        fi
    fi
    cleanup
    return ${RC}
}

export HOME=/home/ubuntu
ARCH=`uname -m`
SDK=""
RUNNERREPO="https://github.com/actions/runner"
while getopts "a:s:" opt
do
    case ${opt} in
        a)
            RUNNERREPO=${OPTARG}
            ;;
        s)
            SDK=${OPTARG}
            ;;
        *)
            exit 4
            ;;
    esac
done
shift $(( OPTIND - 1 ))

if [ -z "${SDK}" ]; then
    case ${ARCH} in
        ppc64le)
            SDK=8
            ;;
        s390x)
            SDK=8
            ;;
    esac
fi

run "$@"
exit $?
