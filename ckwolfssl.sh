#!/bin/dash
# shellcheck shell=dash
# @TODO: change "dash" above to be "sh"; it is as it is now for local testing

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
trap 'cleanup >/dev/null 2>&1' EXIT

# cleaned version of this script's name
name=$(basename -s .sh "$0")

# copies of environment variables, or fall back on defaults
oldPWD=$PWD
cd "$(dirname "$0")" && dir=${PWD:?} || exit 255
config_dir=${CONFIG_DIR:-${dir}}
config_file=${CONFIG_FILE:-config.txt}

# global internal variables
work=${dir}/.tmp/${name}
store=${dir}/.cache/${name}
prefix=${dir}/.local
data=${work}/data
wolfssl_url="https://github.com/wolfssl/wolfssl"
wolfssl_branch="master"
wolfssl_lib_pat="src_libwolfssl_la-*.o"
server_ready=${work}/wolfssl_server_ready
input_file=${work}/cleaned_config
unset failed
ret=0

# modify an environment variable
export LD_LIBRARY_PATH=${prefix}/lib${LD_LIBRARY_PATH+:}$LD_LIBRARY_PATH

# flags with default values
default_threshold=110%
config_database=${config_dir}/${config_file}

# flags without default values
unset verbose
unset current_commit
unset baseline_commit
unset baseline_commit_abs
unset config
unset tests
unset thresholds
unset regenerate

###############################################################################
# cleanup function; allways called on exit
#
# $server_ready: server ready file
# $server_pid:   server PID
# $oldPWD:       where to return to
#
###############################################################################
cleanup() {
    # @temporary: keep $work alive so that we can scrutinize it
    #rm -rf "$work"
    rm -f "$server_ready"
    [ "$PWD" = "${dir?}/wolfssl" ] && git checkout --quiet "$current_commit"
    if pid p "$server_pid" >/dev/null 2>&1
    then
        kill "$server_pid"
        wait "$server_pid"
    fi
    cd "$oldPWD" || exit 255
}

###############################################################################
# Report errors
#
# $1: number of exceeded thresholds
#
# $failed: errors to report
#
# prints report
#
# returns 0 if report was made, 1 if no report was made
###############################################################################
report() {
    [ "$1" -eq 0 ] && return 1

    # print this divider only if we are in verbose mode
    cat >&3 <<END
===============================================================================
END
    cat <<END
Thesholds exceeded: $1

$(echo "$failed" | awk 'NF==3 { print $1, $2, $3 }' RS=";" FS=":" OFS="\t")

config:
$(./config.status --config)
===============================================================================
END
#$(echo "$failed" \
#    | awk 'NF==3 { for (i=1; i<=NF; ++i) print $i }' RS=";" FS=":" OFS="\t")

return 0
}

###############################################################################
# get the raw threshold value for a test from the baseline
#
# $1: test name
# $2: test unit
#
# $default_threshold: default threshold va/ue
#
# prints the threshold
#
# returns 0
###############################################################################
threshold_for() {
    # @temporary: there's probably a more robust way to do this
    case "$thresholds" in
        *"test=$1="*)
            echo "$thresholds" \
                | awk '$2 == str { print $3 }' RS="|" FS="=" str="$1"
            ;;
        *"unit=$2="*)
            echo "$thresholds" \
                | awk '$2 == str { print $3 }' RS="|" FS="=" str="$2"
            ;;
        *)
            echo "$default_threshold"
            ;;
    esac

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
# transform a threshold into an absolute value
#
# $1: threshold
# $2: relative value
#
# prints absolute value
#
# clobbers abs
#
# returns 0 if absolute value is printed, 1 if it is not
###############################################################################
threshold_to_abs() {
    case "$1" in
        ### NOTE: #############################################################
        # ${parameter#word} will remove the word from the front of parameter
        # ${parameter%word} will remove the word from the end of parameter
        #
        # Also, I'm using awk for the math because I like how it prints its
        # numbers.
        #
        [+-]*%) # threshold is a relative percentage
            [ -z "$2" ] && return 1
            abs=${1#"+"}
            abs=$(awk "BEGIN { print ${2} * (100 + ${abs%"%"}) / 100 }")
            ;;
        *%) # threshold is an absolute percentage
            [ -z "$2" ] && return 1
            abs=$(awk "BEGIN { print ${2} * ${1%"%"} / 100 }")
            ;;
        [+-]*) # threshold is a relative value
            [ -z "$2" ] && return 1
            abs=$(awk "BEGIN { print ${2} + ${1#"+"} }")
            ;;
        *) # threshold is an absolute value
            abs=${1}
            ;;
    esac

    echo "$abs"
    return 0
}

###############################################################################
# abstraction wrapper that makes the client and server behave as one
#
# $1: arguments to pass to the server (they will be expanded!)
# $2: arguments to pass to the client (they will be expanded!)
# $3: arguments to pass to both (they will be expanded!)
#
# $server_ready: location of where the server_ready file is to be placed
#
# prints raw client/server output
#
# clobbers server_pid, server_output, client_output, server_return,
#          client_return, counter
#
# overwrites $server_output, $client_output, $server_ready
#
# returns 0 on success, 1 on server fail, 2 on client fail
###############################################################################
client_server() {
    server_output=${work}/server_out
    client_output=${work}/client_out

    # shellcheck disable=2086
    ./examples/server/server $1 $3 -R "$server_ready" >"$server_output" 2>&1 &
    server_pid=$!

    counter=0
    echo "Waiting for server to be ready..." >&3
    until [ -s "$server_ready" ] || [ $counter -gt 19 ]
    do
        sleep 0.1
        counter=$((counter+ 1))
    done

    if pid p $server_pid >/dev/null 2>&1
    then
        echo "ERROR: Server ready file never appeared."
        kill $server_pid
        wait $server_pid
        return 1
    elif [ ! -s "$server_ready" ]
    then
        echo "ERROR: Server failed to start."
        return 1
    fi >&3

    # shellcheck disable=2086
    ./examples/client/client $2 $3 >"$client_output" 2>&1
    client_return=$?

    wait "$server_pid"
    server_return=$?
    unset server_pid
    rm -f "$server_ready"

    cat "$server_output" "$client_output"
    [ $server_return -ne 0 ] && return 1
    [ $client_return -ne 0 ] && return 2
    return 0
}

###############################################################################
# generate data
#
# $wolfssl_lib_pat: pattern for finding .o files
#
# clobbers server_pid, num_connections, num_bytes
#
# prints formated data
#
# returns 0
###############################################################################
generate() {
    # @TODO: add flags to control these two variables
    num_conn=128
    num_bytes=8192 # 8KiB

    # take down file data
    find ./ -type f -name "$wolfssl_lib_pat" -exec du -b {} + \
        | awk  '{ sub(".*/", "", $2); print $1, "B", $2 }' OFS="\t" FS="\t"

    # take down algorithm benchmark data
    ./wolfcrypt/benchmark/benchmark \
        | awk  'function snipe_name() {
                    # use numbers (and surrounding spaces) to break up text
                    split($0, a, /[[:space:]]*[0-9.]+[[:space:]]*/)
                    return $1" "a[2]
                }
                /Cycles/   { print $(NF-0), "cpB", $1 }
                /ops\/sec/ { print $(NF-1), "ops/s", snipe_name() }
               ' OFS="\t"

    # take down connection data
    client_server "-C $num_conn" "-b $num_conn" "-p 11114" \
        | awk  '/wolfSSL_connect/ { print $4, "ms", "connections" }' OFS="\t"

    # take down throughput data
    client_server "" "" "-N -B $num_bytes -p 11115" \
        | awk  'BEGIN       { prefix="ERROR" }
                /Benchmark/ { prefix=$2 }
                /\(.*\)/    { print $5, $6, prefix" "$2 }
               ' OFS="\t" FS="[( \t)]+"

    return 0
}

###############################################################################
# Main function; occurs after command line arguments are parsed
#
# $@: configuration
#
# $work:            work directory
# $data:            data directory
# $baseline_commit: commit to use as baseline
# $current_commit:  commit to return to when we're done
#
# clobers num_failed, failed, base_file, cur_file, oldIFS, threshold, value,
#         unit, max
#
# returns number of exceeded tests (0 included)
###############################################################################
main() {
    num_failed=0
    failed="actual:target:test;" # preload with a header

    # find the file representing this configuration
    base_file="$(grep -lr "[ $1 ]" "$data")"
    if [ -z "$base_file" ]
    then
        # generate baseline data for $config
        echo "INFO: no stored configuration; generating..."

        # make a base_file with a name that won't conflict with anything
        # @temporary: I'm told mktemp is not reliable
        base_file="$(mktemp "${data:?}/XXXXXX")"

        git checkout "$baseline_commit"
        ./autogen.sh
        ./configure "$@" #--prefix="${prefix}"
        make
        #make install

        echo "[ $1 ]" >"$base_file"
        generate >>"$base_file" 2>&4

        git checkout "$current_commit"

    fi >&3 2>&4


    { # generate data for the current commit
        echo "INFO: collecting data for the current commit..."
        ./autogen.sh
        ./configure "$@"
        make

        cur_file="${work:?}/current"

        echo "[ $1 ]" >"$cur_file"
        generate >>"$cur_file" 2>&4
    } >&3 2>&4

    # generate a list of tests if necessary
    if [ -z "${tests+y}" ]
    then
        tests="$(cut -sf 3 <"$cur_file" | paste -sd ,)"
    fi

    # separate the list of tests by commas and store in $@
    oldIFS="$IFS" IFS=','
    # shellcheck disable=SC2086
    set -- $tests
    IFS="$oldIFS"

    echo "Absolute values:" >&3
    printf "cur\tprev\tmax\tunit\tthresh.\ttest\n" >&3
    for each in "$@"
    do
        unset threshold base_value cur_value unit max line

        base_value=$(value_for "$each" "$base_file")
        cur_value=$(value_for "$each" "$cur_file")
        unit=$(unit_for "$each" "$cur_file")

        threshold=$(threshold_for "$each" "$unit")
        max=$(threshold_to_abs "$threshold" "$base_value")

        # build up a line of colon-delimited values
        line="${cur_value:-"---"}"
        line="${line}:${base_value:-"---"}"
        line="${line}:${max:-"N/A"}"
        line="${line}:${unit:-"ERROR"}"
        line="${line}:${threshold:-"ERROR"}"
        line="${line}:${each:-"ERROR"}"

        # report those values to the verbose output descriptor
        echo "$line" \
            | awk '{ print $1, $2, $3, $4, $5, $6 }' FS=":" OFS="\t" >&3

        # only do the math if it makes sense to
        [ -z "$max"       ] && continue
        [ -z "$cur_value" ] && continue

        report_value=$(awk "BEGIN {OFMT=\"%.2f\"
                                   print ($cur_value / $base_value)*100}")%
        report_threshold=$(awk "BEGIN {OFMT=\"%.2f\"
                                       print ($max / $base_value)*100}")%

        # use awk for math because I like how it prints numbers
        exceeded=$(awk "BEGIN {print ($cur_value > $max)}")
        if [ "$exceeded" -eq 1 ]
        then
            num_failed=$((num_failed + 1))
            failed="${failed}$report_value:$report_threshold:$each;"
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
  -g, --generate            always generate baseline data, overwriting existing

 Thresholds:
  -T, --threshold=THRESHOLD default threshold, superseeded by -u and -t
  -uUNIT=THRESHOLD          threshold for tests measured in UNIT
  -tTEST=THRESHOLD          threshold specifically for TEST (supersedes -u)

THRESHOLD may be any integer/floating point number. If it ends with a percent
sign (%), then it will be treated as a percentage of the stored value. If it
starts with a plus or minus (+ or -), it is treated as a relative threshold.
Otherwise, the value of THRESHOLD is treated as an absolute value

UNIT and TEST are case sensitive; they must match exactly with how they appear
in the verbose output "Absolute values" table.
HELP_BLOCK
    return 0
}

optstring='hvc:T:u:t:f:g'
long_opts='help,verbose,tests:,baseline:,threshold:,file:,generate'

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
            case "$1" in
                '-u') type="unit" ;;
                '-t') type="test" ;;
            esac

            # check the argument format
            if ! echo "$2" | grep -q '^[^|=]\+=[+-]\?[0-9.]\+%\?$'
            then
                # @temporary: this isn't a very helpful error message, is it?
                echo "Error: $1$2: invalid"
            else
                # use '=' as the new '\t' and '|' as the new '\n'
                thresholds="${thresholds-}$type=$2|"
            fi
            shift 2
            ;;
        '-T'|'--threshold')
            default_threshold="$2"
            shift 2
            ;;
        '-g'|'--generate')
            regenerate=yes
            shift
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
    # make the directory structure
    mkdir -p "$work"
    mkdir -p "$store"
    mkdir -p "$data"

    # get wolfSSL if neccesary and cd into it
    if [ ! -d "${dir?}/wolfssl" ]
    then
        git clone "$wolfssl_url" -b "$wolfssl_branch" "${dir?}/wolfssl"
        cd "${dir?}/wolfssl" || exit 255
    else
        cd "${dir?}/wolfssl" || exit 255
        git pull --force
    fi

    # get current commit
    current_commit=$(git symbolic-ref --short HEAD \
                   ||git rev-parse --short HEAD)

    # get latest commit
    if [ -z "$baseline_commit" ]
    then
        # Get most resent version of wolfSSL
        location='https://api.github.com/repos/wolfSSL/wolfssl/releases/latest'
        baseline_commit="$(curl -fLsS "$location" | grep "tag_name" \
            | cut -d \" -f 4)"
        baseline_commit_abs="$(git rev-parse "$baseline_commit")"
    fi

    # clean data directory and identify database
    rm -rf "${data:?}"/*
    file="${store:?}/${baseline_commit_abs:?}"

    # open the database if it exists and we don't want to regenerate it
    if [ -f "$file" ] && [ "$regenerate" != "yes" ]
    then
        # split up the database into individual files per configuration
        # @TODO: is csplit portable?
        csplit -q -z -n 6 -f "${data:?}/" "$file" '/\[ .* \]/' '{*}'
    fi

    echo ""
    echo "INFO: current commit:  '$current_commit'"
    echo "INFO: baseline commit: '$baseline_commit'"
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

# remove any line where '#' is the first non-white space character
grep -v '^\s*#' "$config_database" >"$input_file"
exec 5<&0 <"$input_file"
# read from the config database (note redirections above)
while read -r config
do
    echo "INFO: Starting new test."
    # @temporary: prepend CC=clang to all configs
    # shellcheck disable=SC2086
    main CC=clang ${config}
    report "$num_failed" && ret=1
done
exec <&5 5<&-
rm -f "$input_file"

{ # close database
    cat "$data"/* >"${store:?}/${baseline_commit_abs:?}"
    rm -rf "$work"/data
} >&3 2>&4

cd "$oldPWD" || exit 255

exit $ret
