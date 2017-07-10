#!/bin/sh
# Copyright (C) 2006-2017 wolfSSL Inc.
#
# This file is part of wolfSSL.
#
# wolfSSL is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# wolfSSL is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335, USA
###############################################################################
# always run the cleanup function when this script exits
trap 'exit 255' INT KILL QUIT
trap 'cleanup' EXIT

# internal variables
name=$(basename -s .sh "$0")
tmp=$(mktemp -d ".${name}XXXXXX")
lib_pat='src/.libs/src_libwolfssl_la-*.o wolfcrypt/src/.libs/src_libwolfssl_la-*.o'
default_config_dir="."
default_config_file="config.txt"
unset failed
unset server_pid

# make copies of environment variables, using defaults if they are not set
config_dir="${CONFIG_DIR:-${default_config_dir}}"
config_file="${CONFIG_FILE:-${default_config_file}}"

# flag arguments with default values
# @TODO: think about these default values
size_threshold=$(( 8 * 1024 ))
bench_threshold=10
conn_threshold=100
through_threshold=10
database="$config_dir/$config_file"
# get a symbolic reference to HEAD. If that fails, get the hash instead.
current_commit="$(git symbolic-ref --short HEAD || git rev-parse --short HEAD)"

# flag arguments without default values
unset algorithms
unset all
unset baseline_commit
unset config
unset files
unset verbose

###############################################################################
# cleanup; set to always run when this script exits
###############################################################################
cleanup() {
    rm -rf "$tmp"
    git checkout "$current_commit" --quiet
    [ -n "$server_pid" ] && kill $server_pid
}

###############################################################################
# report the failed tests
#
# $1: number of failed tests
#
# return 0 if test reported, 1 if no test reported, or non-zero otherwise
###############################################################################
report() {
    [ $# -ne  1 ] && return 255 # enforce calling convention
    [ $1 -eq  0 ] && return   1 # nothing to report
    [ $1 -ne  1 ] && s=s        # pluralize!

    cat >&3 <<REPORT_BLOCK
===============================================================================
REPORT_BLOCK
    cat <<REPORT_BLOCK
Thresholds exceeded $1 time${s}

REPORT_BLOCK
    # break down $failed by semicolons and store the fields in $@
    oldIFS="$IFS" IFS=';'
    set -- $failed
    IFS="$oldIFS"

    for each in "$@"; do
        # break down $each by colons
        oldIFS="$IFS" IFS=':'
        printf "%s\t%s\t%s\n" $each
        IFS="$oldIFS"
    done
    cat <<REPORT_BLOCK

Configuration:
$(./config.status --config)
===============================================================================
REPORT_BLOCK

    unset s
    return 0
}

###############################################################################
# record stats for present commit.
#
# $1: name for record (usually "baseline" or "current")
#
# return 0 on success, 255 on error
###############################################################################
record_stats_for() {
    [ $# -ne  1 ] && return 255 # enforce calling convention

    # @TODO: should there be flags to control num and size?
    num=128
    size=$(( 128 * 1024 * 1024 )) # 128 MB

    echo "Taking down $1 size"
    du -b $lib_pat >"$tmp/$1_size"

    echo "Taking down $1 benchmark"
    ./wolfcrypt/benchmark/benchmark >"$tmp/$1_bench"

    # start up the echoserver
    examples/echoserver/echoserver 1>/dev/null 2>/dev/null &
    server_pid=$!

    echo "Taking down $1 TLS connection benchmark"
    ./examples/client/client -b $num >"$tmp/$1_conn"

    echo "Taking down $1 TLS throughput benchmark"
    ./examples/client/client -B $size >"$tmp/$1_through"

    { # kill the echoserver
        kill $server_pid
        wait
    } 1>/dev/null 2>/dev/null
    unset server_pid
    return 0
}

###############################################################################
# Checkout and build a commit of wolfSSL
#
# $1: commit to check out before building (any valid git refenence)
#
# return 0 on success, non-zero otherwise
###############################################################################
build_wolfssl() {
    [ $# -ne  1 ] && return 255 # enforce calling convention

    # the below will cause build_wolfssl to fail if any command fails
    git checkout "$1"   || return $?
    ./autogen.sh        || return $?
    ./configure $config || return $?
    make
    return $?
}

###############################################################################
# calculate and check the delta against the threshold
#
# $1: baseline
# $2: current
# $3: threshold
# $4: units
# $5: test name
#
# return 0 on success, non-zero on failure
###############################################################################
check_delta() {
    [ $# -ne  5 ] && return 255 # enforce calling convention

    # use awk for math because it produces prettier numbers than bc
    delta=$(awk "BEGIN {print ($2 - $1)}")
    excess=$(awk "BEGIN {print ($delta - $3)}")

    printf "%s\t%s\n" "$delta" "$5"
    if [ $(awk "BEGIN {print ($excess > 0)}") -eq 1 ]; then
        failed="$failed;$excess:$4:$5"
        num_failed=$(( num_failed + 1))
    fi
    return 0
}

###############################################################################
# Main function; occurs after command line arguments are parsed
#
# return number of exceeded otherwise (0 included)
###############################################################################
main() {
    echo "Info: starting new test." >&3
    num_failed=0

    #preload failed with headding column
    failed='excess:unit:test'

    # collect raw statistics for later processing
    { # these braces allow for mass redirection
        build_wolfssl "$baseline_commit"
        record_stats_for baseline
        build_wolfssl "$current_commit"
        record_stats_for current
    } 1>&3 2>&4
    # stats written to $tmp/{baseline,current}_{size,bench,conn,through}

    ###########################################################################
    # files:
    ###########################################################################
    printf "File deltas:\n" >&3

    # in the below, we only care if files is unset. An empty list is acceptable
    if [ -z ${files+x} ]; then
        # Get a comma separated list off all files
        files="$(cut -f 2 <"$tmp/current_size" | xargs -n 1 basename \
                | paste -sd ",")"
    fi

    # break down $files by commas and store the fields in $@
    oldIFS="$IFS" IFS=','
    set -- $files
    IFS="$oldIFS"

    # calculate and check file size deltas
    for each in "$@"; do
        current_line=$(grep -i "$each" "$tmp/current_size")
        baseline_line=$(grep -i "$each" "$tmp/baseline_size")

        if [ -z "$current_line" ]; then
            echo "No data for $each in $current_commit." >&4
            continue;
        elif [ -z "$baseline_line" ]; then
            echo "No data for $each in $baseline_commit." >&4
            continue
        fi

        current=$(echo "$current_line" | cut -f 1 )
        baseline=$(echo "$baseline_line" | cut -f 1 )

        check_delta "$baseline" "$current" "$size_threshold" B "$each" >&3
    done

    ###########################################################################
    # algorithms:
    ###########################################################################
    printf "\nAlgorithm deltas:\n" >&3

    # in the below, we only care if files is unset. An empty list is acceptable
    if [ -z ${algorithms+x} ]; then
        # Get a comma separated list off all algorithms
        # @TEMP: only handle algorithms that have "Cycles per byte" values
        algorithms="$(awk '/Cycles/ {print $1}' <"$tmp/current_bench" \
                     | paste -sd ",")"
    fi

    # break down $algorithms by commas and store the fields in $@
    oldIFS="$IFS" IFS=','
    set -- $algorithms
    IFS="$oldIFS"

    # calculate and check cpB deltas
    for each in "$@"; do
        current_line=$(grep -i "^$each\s" "$tmp/current_bench")
        baseline_line=$(grep -i "^$each\s" "$tmp/baseline_bench")

        if [ -z "$current_line" ]; then
            echo "No data for $each in $current_commit." >&4
            continue;
        elif [ -z "$baseline_line" ]; then
            echo "No data for $each in $baseline_commit." >&4
            continue
        fi

        current=$(echo "$current_line" | awk '{print $13}' )
        baseline=$(echo "$baseline_line" | awk '{print $13}' )

        # @NOTE: for now, this script can only track the delta for cpB
        check_delta "$baseline" "$current" "$bench_threshold" cpB "$each" >&3
    done

    # calculate and check TLS connections delta
    name="TLS connection"
    current=$(awk '{print $4}' <"$tmp/current_conn")
    baseline=$(awk '{print $4}' <"$tmp/baseline_conn")

    check_delta "$baseline" "$current" "$conn_threshold" ms "$name" >&3

    # calculate and check TLS throughput deltas
    name="TLS throughput"
    for each in TX RX; do
        current_line=$(grep "$each" "$tmp/current_through")
        baseline_line=$(grep "$each" "$tmp/baseline_through")

        if [ -z "$current_line" ]; then
            echo "No data for $each in $current_commit." >&3
            continue;
        elif [ -z "$baseline_line" ]; then
            echo "No data for $each in $baseline_commit." >&3
            continue
        fi

        current=$(echo "$current_line" | awk '{print $5}' )
        baseline=$(echo "$baseline_line" | awk '{print $5}' )

        check_delta "$baseline" "$current" "$through_threshold" MBps "$name ($each)" >&3
    done

    return $num_failed
}



print_help() {
    cat << HELP_BLOCK
Usage: $0 [OPTION]... [-- [config]...]
Check the compile size and performance characteristics of wolfSSL for a known
configuration against a previous version.

This script expects to be run from the wolfSSL root directory.

 Control:
  -A, --all                 run once for every line in the database
  -a, --algorithms=LIST     comma separated list of algorithms to check
  -c, --baseline=commit     git commit to treat as last known good commit
  -d, --database=FILE       file containing known configurations (implies -A)
  -f, --files=LIST          comma separated list of files to check
  -h, --help                display this help and exit
  -v, --verbose             report the deltas of each test

 Thresholds:
  -b, --bench=THRESHOLD     minimum acceptable performance delta in cpB
  -s, --size=THRESHOLD      minimum acceptable file size delta in B
  -t, --time=THRESHOLD      minimum acceptable connection time delta in ms
  -T, --through=THRESHOLD   minimum acceptable throughput speed delta in MBps

CONFIGs will be used as the known configuration. The "--" is neccesary to
prevent CONFIGs from being interpreted as flags. If no CONFIGs are specified,
this is understood to mean a configuration with no flags. If "--all" is set,
all CONFIGs are ignored.

By default, "--database" is \$CONFIG_DIR/\$CONFIG_FILE, which are environment
variables. When neither are envirenment variable is set, this defaults to
$default_config_dir/$default_config_file

For both "--algorithms" and "--files", if the flag do not appear, all
algorithms or files (dending on which flag) for which there exists data in the
current commit will be checked. An empty list is a valid list. For
"--algorithms", the names should match (case insensitive) with how the
benchmark program reports them.
HELP_BLOCK
    return 0
}

optstring='s:b:a::c:hvd:f::Aqt:T:'
long_opts='size:,bench:,algorithms:,baseline:,help,verbose,database:,files,all,quiet,time:,through'

# reorder the command line arguments to make it easier to parse
opts=$(getopt -o "$optstring" -l "$long_opts" -n "$0" -- "$@")
if [ $? -ne 0 ]; then
    echo "Error has occurred with getopt. Exiting." >&2
    exit 255
fi

# use of eval necessary to preserve spaces in arguments
eval set -- "$opts"
unset opts

while true; do
    case "$1" in
        '-s'|'--size')
            size_threshold="$2"
            shift 2
            ;;
        '-b'|'--bench')
            bench_threshold="$2"
            shift 2
            ;;
        '-t'|'--time')
            conn_threshold="$2"
            shift 2
            ;;
        '-T'|'--through')
            through_threshold="$2"
            shift 2
            ;;
        '-a'|'--algorithms')
            algorithms="$2"
            shift 2
            ;;
        '-f'|'--files')
            files="$2"
            shift 2
            ;;
        '-c'|'--baseline')
            baseline_commit="$2"
            shift 2
            ;;
        '-v'|'--verbose')
            verbose=yes
            shift
            ;;
        '-h'|'--help')
            print_help
            exit 0
            ;;
        '-d'|'--database')
            database="$2"
            all=yes
            shift 2
            ;;
        '-A'|'--all')
            all=yes
            shift
            ;;
        '--')
            shift
            break
            ;;
        *)
            echo "Internal error!" >&2
            exit 255
            ;;
    esac
done

# All remaining arguments are configure flags.

if [ -z "$baseline_commit" ]; then
    # Get most resent version of wolfSSL
    location='https://api.github.com/repos/wolfSSL/wolfssl/releases/latest'
    baseline_commit="$(curl -fLsS "$location" | grep "tag_name" \
                      | cut -d \" -f 4)"
fi

# use file descriptors 3 and 4 as verbose output channels (out and err
# respectively). If --verbose is used, redirect 3 and 4 to 1 and 2
# respectively, else redirect each to /dev/null
if [ "$verbose" = "yes" ]; then
    exec 3>&1 4>&2
else
    exec 3>/dev/null 4>&3
fi

{ # echo commit info as verbose information
    echo "INFO: current commit: $current_commit"
    echo "INFO: baseline commit: $baseline_commit"
    echo ""
} 1>&3 2>&4


{ # report thresholds
    # @TEMP: not very future-proof; likely to become out-of-date if new
    # thresholds are added or their units change
    printf "Delta threshold values:\n"
    printf "File size\t${size_threshold} B\n"
    printf "Benchmark\t${bench_threshold} cpB\n"
    printf "Connection\t${conn_threshold} ms\n"
    printf "Throughput\t${through_threshold} MBps\n"
}

ret=0
if [ "$all" = "yes" ]; then
    # loop for every line of $database where '#' is not the first
    # non-whitespace character.
    grep -v "^\s*#" "$database" | while read config; do
        # @TEMP: prepend CC=clang to all configs
        config="CC=clang $*"
        main
        report $? && ret=1
    done
else
    # @TEMP: prepend CC=clang to config
    config="CC=clang $*"
    main
    report $? && ret=1
fi

exit $ret
