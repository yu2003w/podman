#!/usr/bin/env bats

load helpers

@test "podman info - basic test" {
    run_podman info

    expected_keys="
buildahVersion: *[0-9.]\\\+
conmon:\\\s\\\+package:
distribution:
logDriver:
ociRuntime:\\\s\\\+name:
os:
rootless:
registries:
store:
graphDriverName:
graphRoot:
graphStatus:
imageStore:\\\s\\\+number: 1
runRoot:
cgroupManager: \\\(systemd\\\|cgroupfs\\\)
cgroupVersion: v[12]
"
    defer-assertion-failures

    while read expect; do
        is "$output" ".*$expect" "output includes '$expect'"
    done < <(parse_table "$expected_keys")
}

@test "podman info - json" {
    run_podman info --format=json

    expr_nvr="[a-z0-9-]\\\+-[a-z0-9.]\\\+-[a-z0-9]\\\+\."
    expr_path="/[a-z0-9\\\/.-]\\\+\\\$"

    # FIXME: if we're ever able to get package versions on Debian,
    #        add '-[0-9]' to all '*.package' queries below.
    tests="
host.buildahVersion       | [1-9][0-9]*\.[0-9.]\\\+.*
host.conmon.path          | $expr_path
host.conmon.package       | .*conmon.*
host.cgroupManager        | \\\(systemd\\\|cgroupfs\\\)
host.cgroupVersion        | v[12]
host.networkBackendInfo   | .*dns.*package.*
host.ociRuntime.path      | $expr_path
host.pasta                | .*executable.*package.*
store.configFile          | $expr_path
store.graphDriverName     | [a-z0-9]\\\+\\\$
store.graphRoot           | $expr_path
store.imageStore.number   | 1
host.slirp4netns.executable | $expr_path
"

    defer-assertion-failures

    while read field expect; do
        actual=$(echo "$output" | jq -r ".$field")
        dprint "# actual=<$actual> expect=<$expect>"
        is "$actual" "$expect" "jq .$field"
    done < <(parse_table "$tests")
}

@test "podman info - confirm desired runtime" {
    if [[ -z "$CI_DESIRED_RUNTIME" ]]; then
        # When running in Cirrus, CI_DESIRED_RUNTIME *must* be defined
        # in .cirrus.yml so we can double-check that all CI VMs are
        # using crun/runc as desired.
        if [[ -n "$CIRRUS_CI" ]]; then
            die "CIRRUS_CI is set, but CI_DESIRED_RUNTIME is not! See #14912"
        fi

        # Not running under Cirrus (e.g., gating tests, or dev laptop).
        # Totally OK to skip this test.
        skip "CI_DESIRED_RUNTIME is unset--OK, because we're not in Cirrus"
    fi

    run_podman info --format '{{.Host.OCIRuntime.Name}}'
    is "$output" "$CI_DESIRED_RUNTIME" "CI_DESIRED_RUNTIME (from .cirrus.yml)"
}

@test "podman info - confirm desired network backend" {
    if [[ -z "$CI_DESIRED_NETWORK" ]]; then
        # When running in Cirrus, CI_DESIRED_NETWORK *must* be defined
        # in .cirrus.yml so we can double-check that all CI VMs are
        # using netavark or cni as desired.
        if [[ -n "$CIRRUS_CI" ]]; then
            die "CIRRUS_CI is set, but CI_DESIRED_NETWORK is not! See #16389"
        fi

        # Not running under Cirrus (e.g., gating tests, or dev laptop).
        # Totally OK to skip this test.
        skip "CI_DESIRED_NETWORK is unset--OK, because we're not in Cirrus"
    fi

    run_podman info --format '{{.Host.NetworkBackend}}'
    is "$output" "$CI_DESIRED_NETWORK" "CI_DESIRED_NETWORK (from .cirrus.yml)"
}

@test "podman info - confirm desired database" {
    # Always run this and preserve its value. We will check again in 999-*.bats
    run_podman info --format '{{.Host.DatabaseBackend}}'
    db_backend="$output"
    echo "$db_backend" > $BATS_SUITE_TMPDIR/db-backend

    if [[ -z "$CI_DESIRED_DATABASE" ]]; then
        # When running in Cirrus, CI_DESIRED_DATABASE *must* be defined
        # in .cirrus.yml so we can double-check that all CI VMs are
        # using netavark or cni as desired.
        if [[ -n "$CIRRUS_CI" ]]; then
            die "CIRRUS_CI is set, but CI_DESIRED_DATABASE is not! See #16389"
        fi

        # Not running under Cirrus (e.g., gating tests, or dev laptop).
        # Totally OK to skip this test.
        skip "CI_DESIRED_DATABASE is unset--OK, because we're not in Cirrus"
    fi

    is "$db_backend" "$CI_DESIRED_DATABASE" "CI_DESIRED_DATABASE (from .cirrus.yml)"
}

@test "podman info - confirm desired storage driver" {
    if [[ -z "$CI_DESIRED_STORAGE" ]]; then
        # When running in Cirrus, CI_DESIRED_STORAGE *must* be defined
        # in .cirrus.yml so we can double-check that all CI VMs are
        # using overlay or vfs as desired.
        if [[ -n "$CIRRUS_CI" ]]; then
            die "CIRRUS_CI is set, but CI_DESIRED_STORAGE is not! See #20161"
        fi

        # Not running under Cirrus (e.g., gating tests, or dev laptop).
        # Totally OK to skip this test.
        skip "CI_DESIRED_STORAGE is unset--OK, because we're not in Cirrus"
    fi

    is "$(podman_storage_driver)" "$CI_DESIRED_STORAGE" "podman storage driver is not CI_DESIRED_STORAGE (from .cirrus.yml)"
}

# 2021-04-06 discussed in watercooler: RHEL must never use crun, even if
# using cgroups v2.
@test "podman info - RHEL8 must use runc" {
    local osrelease=/etc/os-release
    test -e $osrelease || skip "Not a RHEL system (no $osrelease)"

    local osname=$(source $osrelease; echo $NAME)
    if [[ $osname =~ Red.Hat || $osname =~ CentOS ]]; then
        # Version can include minor; strip off first dot an all beyond it
        local osver=$(source $osrelease; echo $VERSION_ID)
        test ${osver%%.*} -le 8 || skip "$osname $osver > RHEL8"

        # RHEL or CentOS 8.
        # FIXME: what does 'CentOS 8' even mean? What is $VERSION_ID in CentOS?
        is "$(podman_runtime)" "runc" "$osname only supports OCI Runtime = runc"
    else
        skip "only applicable on RHEL, this is $osname"
    fi
}

@test "podman info --storage-opt='' " {
    skip_if_remote "--storage-opt flag is not supported for remote"
    skip_if_rootless "storage opts are required for rootless running"
    run_podman --storage-opt='' info
    # Note this will not work in rootless mode, unless you specify
    # storage-driver=vfs, until we have kernels that support rootless overlay
    # mounts.
    is "$output" ".*graphOptions: {}" "output includes graphOptions: {}"
}

@test "podman info netavark " {
    # Confirm netavark in use when explicitly required by execution environment.
    if [[ "$NETWORK_BACKEND" == "netavark" ]]; then
        if ! is_netavark; then
            # Assume is_netavark() will provide debugging feedback.
            die "Netavark driver testing required, but not in use by podman."
        fi
    else
        skip "Netavark testing not requested (\$NETWORK_BACKEND='$NETWORK_BACKEND')"
    fi
}

@test "podman --root PATH info - basic output" {
    if ! is_remote; then
        run_podman --storage-driver=vfs --root ${PODMAN_TMPDIR}/nothing-here-move-along info --format '{{ .Store.GraphOptions }}'
        is "$output" "map\[\]" "'podman --root should reset GraphOptions to []"
    fi
}

@test "rootless podman with symlinked $HOME" {
    # This is only needed as rootless, but we don't have a skip_if_root
    # And it will not hurt to run as root.
    skip_if_remote "path validation is only done in libpod, does not effect remote"

    new_home=$PODMAN_TMPDIR/home

    ln -s /home $new_home

    # Just need the command to run cleanly
    HOME=$PODMAN_TMPDIR/$HOME run_podman info

    rm $new_home
}

@test "podman --root PATH --volumepath info - basic output" {
    volumePath=${PODMAN_TMPDIR}/volumesGoHere
    if ! is_remote; then
        run_podman --storage-driver=vfs --root ${PODMAN_TMPDIR}/nothing-here-move-along --volumepath ${volumePath} info --format '{{ .Store.VolumePath }}'
        is "$output" "${volumePath}" "'podman --volumepath should reset VolumePath"
    fi
}

@test "CONTAINERS_CONF_OVERRIDE" {
    skip_if_remote "remote does not support CONTAINERS_CONF*"

    # Need to include runtime because it's runc in debian CI,
    # and crun 1.11.1 barfs with "read from sync socket"
    containersConf=$PODMAN_TMPDIR/containers.conf
    cat >$containersConf <<EOF
[engine]
runtime="$(podman_runtime)"

[containers]
env = [ "CONF1=conf1" ]

[engine.volume_plugins]
volplugin1  = "This is not actually used or seen anywhere"
EOF

    overrideConf=$PODMAN_TMPDIR/override.conf
    cat >$overrideConf <<EOF
[containers]
env = [ "CONF2=conf2" ]

[engine.volume_plugins]
volplugin2  = "This is not actually used or seen anywhere, either"
EOF

    CONTAINERS_CONF="$containersConf" run_podman 1 run --rm $IMAGE printenv CONF1 CONF2
    is "$output" "conf1" "with CONTAINERS_CONF only"

    CONTAINERS_CONF_OVERRIDE=$overrideConf run_podman 1 run --rm $IMAGE printenv CONF1 CONF2
    is "$output" "conf2" "with CONTAINERS_CONF_OVERRIDE only"

    # CONTAINERS_CONF will be overridden by _OVERRIDE. env is overridden, not merged.
    CONTAINERS_CONF=$containersConf CONTAINERS_CONF_OVERRIDE=$overrideConf run_podman 1 run --rm $IMAGE printenv CONF1 CONF2
    is "$output" "conf2" "with both CONTAINERS_CONF and CONTAINERS_CONF_OVERRIDE"

    # Merge test: each of those conf files defines a distinct volume plugin.
    # Confirm that we see both. 'info' outputs in random order, so we need to
    # do two tests.
    CONTAINERS_CONF=$containersConf CONTAINERS_CONF_OVERRIDE=$overrideConf run_podman info --format '{{.Plugins.Volume}}'
    assert "$output" =~ "volplugin1" "CONTAINERS_CONF_OVERRIDE does not clobber volume_plugins from CONTAINERS_CONF"
    assert "$output" =~ "volplugin2" "volume_plugins seen from CONTAINERS_CONF_OVERRIDE"

}

# vim: filetype=sh
