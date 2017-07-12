#!/bin/dash
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
trap 'exit 255' INT QUIT
trap 'cleanup' EXIT

# internal variables
name="$(basename -s .sh "$0")"
oldPWD="$PWD"
{ # get absolute path for dir
    cd "$(dirname "$0")" || exit 255
    dir="$PWD"
}
work="${dir}/.tmp"
[ ! -d "$work" ] && mkdir -p "$work"
store="${dir}/.cache/${name}"
[ ! -d "$store" ] && mkdir -p "$store"
default_config_dir="$dir"
default_config_file="config.txt"
wolfssl_url="https://github.com/wolfssl/wolfssl"
wolfssl_branch="master"
wolfssl_lib_pat='src_libwolfssl_la-*.o'
ret=0
unset failed
unset file

# make copies of environment variables, or fall back on defaults
config_dir=${CONFIG_DIR:-${default_config_dir}}
config_file=${CONFIG_FILE:-${default_config_file}}

# flags with default values
default_threshold="110%"
config_database="${config_dir}/${config_file}"
current_commit="$(git symbolic-ref --short HEAD || git rev-parse --short HEAD)"
thresholds="|" # pre-set leading divider

# flags without default values
unset verbose
unset baseline_commit
unset baseline_commit_abs
unset config
unset tests

###############################################################################
# cleanup function; allways called on exit
###############################################################################
cleanup() {
    # @temporary: keep $work alive so that we can scrutinize it
    #rm -rf "$work"
    [ "$PWD" = "$dir/wolfssl" ] && git checkout --quiet "$current_commit"
    cd "$oldPWD" || exit 255
}

###############################################################################
# Report errors
#
# $num_failed: number of errors
# $failed:     errors
#
# prints report
#
# clobbers oldIFS
#
# returns 0 if report was made, 1 if no report was made
###############################################################################
report() {
    [ $# -ne 1 ] && return 255
    [ "$num_failed" -eq 0 ] && return 1

    # print this divider only if we are in verbose mode
    cat >&3 <<END
===============================================================================
END
cat <<END
Thesholds exceeded: $1

END
# break up $failed by semicolons and store them in $@
oldIFS="$IFS" IFS=';'
eval 'set -- $failed'
IFS="$oldIFS"

for each in "$@"
do
    # break up $each by conlons and store in $@
    echo "$each" | awk '{print $1, $2, $3, $3}' FS=":" OFS="\t"
done
cat <<END

config:
$(./config.status --config)
===============================================================================
END

return 0
}

###############################################################################
# get the threshold for a test from the baseline
#
# $1: test name
# $2: file with stored baseline data
#
# $baseline_commit: for reporting
#
# clobbers line, unit, value, relative_threshold
#
# prints the threshold if it exists
#
# returns 0 if the threshold exists, non-zero if it does not
###############################################################################
threshold_for() {
    # find the line in the database
    line="$(grep "$1$" "$2")"

    # check to make sure the line exists
    if [ -z "$line" ]
    then
        printf -- '---\t---\t---\t%s\n' "$1 (stored)" >&3
        return 1
    else
        echo "$line" \
            | awk '{print $1, $2, "---", $3" (stored)"}' FS="\t" OFS="\t" >&3
    fi

    # retrive unit and value from the database
    unit="$(echo "$line" | cut -sf 2)"
    value="$(echo "$line" | cut -sf 1)"

    # extract threshold
    case "$thresholds" in
        *"|$1="*)
            threshold="$(echo "$thresholds" \
                | sed "s/^.*|$1=\([^|]*\)|.*$/\1/")"
            ;;
        *"|$unit="*)
            threshold="$(echo "$thresholds" \
                | sed "s/^.*|$unit=\([^|]*\)|.*$/\1/")"
            ;;
        *)
            threshold="$default_threshold"
            ;;
    esac

    case "$threshold" in
        *"%")
            # use ${parameter%word} construct to strip trailing '%'
            awk "BEGIN {print ${value} * ${threshold%"%"} / 100}"
            ;;
        "+"*|"-"*)
            # use ${parameter#word} construct to strip leading '+'
            awk "BEGIN {print ${value} * ${threshold#"+"} / 100}"
            ;;
        *)
            # treat the threshold as an absolute value
            echo "$threshold"
            ;;
    esac

    unset file line unit value relative_threshold
    return 0
}

###############################################################################
# get the unit for a test
#
# $1: test
# $2: database
#
# prints the unit
#
# returns 0
###############################################################################
unit_for() {
    grep "$1$" "$2" | cut -sf 2
    return 0
}

###############################################################################
# get the value for a test
#
# $1: test
# $2: database
#
# prints the value
#
# returns 0
###############################################################################
value_for() {
    grep "$1$" "$2" | cut -sf 1
    return 0
}

###############################################################################
# Retrieve database of stored configuration data. In the end, one file per
# commit will be placed into $work/data/, which is first cleaned.
#
# $work:                work directory
# $store:               directory where databases are stored
# $baseline_commit_abs: name of database file
#
# clobbers file
#
# returns 0
###############################################################################
open_database() {
    rm -rf "$work/data/"
    file="$store/$baseline_commit_abs"
    mkdir "$work/data/"

    # test if we need to generate the database
    if [ ! -f "$file" ]
    then
        # make $store if there is a need to
        [ ! -d "$store" ] && mkdir "$store"

        # nothing to do
    else
        # split up the database into individual files per configuration
        csplit -z -n 6 -f "$work/data/" "$file" '/\[ .* \]/' '{*}'
    fi

    return 0
}

###############################################################################
# Put all of the individual files back into a single file and clean up
#
# $work:                work directory
# $store:               directory where databases are stored
# $baseline_commit_abs: name of database file
#
# returns 0
###############################################################################
close_database() {
    cat "$work/data"/* >"$store/$baseline_commit_abs"
    rm -rf "$work"/data
}

###############################################################################
# generate data
#
# $wolfssl_lib_pat: pattern for .o files
#
# clobbers server_pid, num_connections, num_bytes
#
# prints formated data
#
# returns 0
###############################################################################
generate() {
    num_connections=100
    num_bytes=8192 # 8KiB

    # take down file data
    find ./ -type f -name "$wolfssl_lib_pat" -exec du -b {} + \
        | awk '{ sub(".*/", "", $2); print $1, "B", $2 }' OFS="\t"

    # take down algorithm benchmark data
    # @temporary: only do data for benchmarks with cpB values
    ./wolfcrypt/benchmark/benchmark \
        | awk '/Cycles/ { print $13, "cpB", $1 }' OFS="\t"

    # @TODO: don't use scripts/benchmark: server output is fucky
    # take down connection data
    ./scripts/benchmark.test 1 "$num_connections" \
        | awk '/wolfSSL_connect/ { print $4, "ms", "connections" }' OFS="\t"

    # @TODO: don't use scripts/benchmark: server output is fucky
    # take down throughput data
    ./scripts/benchmark.test 2 "$num_bytes" \
        | awk 'BEGIN       { prefix="ERROR" }
               /Benchmark/ { prefix=$2 }
               /\(.*\)/    { print $5, $6, prefix" "$2 }
              ' OFS="\t" FS="[( \t)]+"

    return 0
}

###############################################################################
# Main function; occurs after command line arguments are parsed
#
# $1: configuration
#
# $work:            work directory
# $baseline_commit: commit to use as baseline
# $current_commit:  commit to return to when we're done
#
# clobers num_failed, failed, base_file, cur_file, oldIFS, threshold, value,
#         unit
#
# returns number of exceeded tests (0 included)
###############################################################################
main() {
    num_failed=0
    failed="excess:unit:test;" # preload with a header

    # find the file representing this configuration
    base_file="$(grep -lr "[ $1 ]" "$work/data/")"
    if [ -z "$base_file" ]
    then
        # generate baseline data for $config
        echo "INFO: no stored configuration; generating..."

        # make a base_file with a name that won't conflict with anything
        [ ! -d "$work/data" ] && mkdir "$work/data"
        base_file="$(mktemp "$work/data/XXXXXX")"
        git checkout "$baseline_commit"
        ./autogen.sh
        echo "$1" | xargs ./configure
        make

        echo "[ $1 ]" >"$base_file"
        generate >>"$base_file"

        git checkout "$current_commit"

        echo "INFO: generation complete"
    fi >&3 2>&4


    { # generate data for the current commit
        ./autogen.sh
        echo "$1" | xargs ./configure
        make

        cur_file="$work/current"

        echo "[ $1 ]" >"$cur_file"
        generate >>"$cur_file"
    } >&3 2>&4

    # generate a list of tests if necessary
    if [ -z "${tests+y}" ]
    then
        tests="$(cut -sf 3 <"$cur_file" | paste -sd ,)"
    fi

    # separate the list of tests by commas and store in $@
    oldIFS="$IFS" IFS=','
    eval 'set -- $tests'
    IFS="$oldIFS"

    echo "Absolute values:" >&3
    printf "value\tunit\tmax\ttest\n" >&3
    for each in "$@"
    do
        threshold="$(threshold_for "$each" "$base_file")"
        value="$(value_for "$each" "$cur_file")"
        unit="$(unit_for "$each" "$cur_file")"
        echo "$value:$unit:${threshold:-"---"}:$each (current)" \
            | awk '{print $1, $2, $3, $4}' FS=":" OFS="\t" >&3
        [ -z "$threshold" ] && continue

        # use awk for math because I like how it prints numbers
        excess="$(awk "BEGIN {print ($value - $threshold)}")"
        exceeded="$(awk "BEGIN {print ($value > $threshold)}")"
        if [ "$exceeded" -eq 1 ]
        then
            num_failed=$((num_failed + 1))
            failed="${failed}$excess:$unit:$each;"
        fi
    done

    return $num_failed
}



print_help() {
    # @TODO: review
    cat <<HELP_BLOCK
Usage: $0 [OPTION]...
Check the compile size and performance characteristics of wolfSSL for a known
configuration against a previous version.

 Control:
  -h, --help                display this help page then exit
  -v, --verbose             display extra information
      --tests=LIST          comma separated list of tests to perform
  -c, --baseline=COMMIT     commit to treat as baseline
  -f, --file=FILE           file from which to read configurations

 Thresholds:
  -T, --threshold=THRESHOLD default threshold
  -uUNIT=THRESHOLD          threshold for tests measured in UNIT
  -tTEST=THRESHOLD          threshold specifically for TEST

THRESHOLD may be any integer/floating point number. If it ends with a percent
sign (%), then it will be treated as a percentage of the stored value. If it
starts with a plus or minus (+ or -), it is treated as a relative threshold.
Otherwise, the value of THRESHOLD is treated as an absolute value

@temporary: cannot stack + or - with %. This should be implemented eventually

UNIT and TEST are case sensitive.
HELP_BLOCK
    return 0
}

optstring='hvc:T:u:t:f:'
long_opts='help,verbose,tests:,baseline:,threshold:,file:'

# reorder the command line arguments to make it easier to parse
opts=$(getopt -o "$optstring" -l "$long_opts" -n "$0" -- "$@")
if test $? -ne 0
then
    echo "Error has occurred with getopt. Exiting." >&2
    exit 255
fi

# use of eval necessary to preserve spaces in arguments
eval set -- "$opts"
unset opts

while true
do
    case "$1" in
        '-u'|'-t')
            # @temporary: no way to distinguish -u from -t: they have purely
            # semantic meaning

            # check the argument format
            if ! echo "$2" | grep -q '^[a-zA-Z0-9_ -]\+=[+-]\?[0-9.]\+%\?$'
            then
                # @temporary: this isn't a very helpful error message, is it.
                echo "Error: $1$2: invalid"
                shift 2
                continue
            fi

            thresholds="${thresholds}$2|"
            shift 2
            ;;
        '-T'|'--threshold')
            default_threshold="$2"
            shift 2
            ;;
        '--tests')
            tests="$2"
            shift 2
            ;;
        '-f'|'--file')
            if [ "$2" = "-" ]
            then
                config_database="/proc/self/fd/0"
            else
                config_database="$2"
            fi
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
        '--')
            shift
            break
            ;;
        *)
            echo "Error: internal to getopts!" >&2
            exit 255
            ;;
    esac
done

# @temporary

# use file descriptors 3 and 4 as verbose output channels (out and err
# respectively). If --verbose is used, redirect 3 and 4 to 1 and 2
# respectively, else redirect each to /dev/null
if [ "$verbose" = "yes" ]
then
    exec 3>&1 4>&2
else
    exec 3>/dev/null 4>&3
fi

{ # do setup

    # get wolfSSL if neccesary and cd into it
    if [ ! -d "$dir/wolfssl" ]
    then
        git clone "$wolfssl_url" -b "$wolfssl_branch" "$dir/wolfssl"
        cd "$dir/wolfssl" || exit 255
    else
        cd "$dir/wolfssl" || exit 255
        git pull --force
    fi

    # get latest commit
    if [ -z "$baseline_commit" ]
    then
        # Get most resent version of wolfSSL
        location='https://api.github.com/repos/wolfSSL/wolfssl/releases/latest'
        baseline_commit="$(curl -fLsS "$location" | grep "tag_name" \
            | cut -d \" -f 4)"
        baseline_commit_abs="$(git rev-parse "$baseline_commit")"
    fi

    open_database

    echo ""
    echo "INFO: current commit: $current_commit"
    echo "INFO: baseline commit: $baseline_commit"
    echo ""
} >&3 2>&4

### NOTE: #####################################################################
# I would have loved to use a `cat FILE | while read var` construct here, but
# apparently that makes this entire while loop run in a subshell, meaning that
# I would not be able to change the value of $ret from here. Similarly, in good
# ol' sh, even doing redirection with '<' would put this loop into a subshell.
# As such, the maddness of saving &0 in &5, redirecting $tmp to be &0, then
# finally restoring &0 and closing &5 is the most POSIXly correct way of doing
# this such that I can still modify the $ret variable.
#
tmp_input_file="$(mktemp)"
# remove any line where '#' is the first non-white space character
grep -v '^\s*#' "$config_database" >"$tmp_input_file"
exec 5<&0 <"$tmp_input_file"
# read from the config database (note redirections above)
while read -r config
do
    # @temporary: prepend CC=clang to all configs
    main "CC=clang $config"
    report "$num_failed" && ret=1
done
exec <&5 5<&-
rm -f "$tmp_input_file"
unset tmp_input_file

close_database
cd "$oldPWD" || exit 255

exit $ret
