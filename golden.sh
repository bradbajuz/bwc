#!/usr/bin/env bash
# golden.sh - differential test harness: bwc vs GNU wc (the oracle)

BWC=./zig-out/bin/bwc
zig build || exit 1

pass=0
fail=0
xfail=0
xpass=0

# --- setup: fixtures git can't represent (permissions) ---
rm -f testdir/noperm.txt
echo "secret" >testdir/noperm.txt
chmod 000 testdir/noperm.txt

# --- expected divergences (see CHECKLIST.md) ---
# item 8: -L counts bytes, wc counts display width
# item 10: -w counts undecodable bytes as word chars
# item 11: directory arg -> wc falls back to width 7
expected_diffs=(
    # item 8: -L counts bytes, not display width
    "file -L utf8test.txt" "file -l -w -c -m -L utf8test.txt" "stdin all: utf8"
    "file -L bad.bin" "file -l -w -c -m -L bad.bin"
    "stdin -L: utf8"
    # item 10: -w counts undecodable bytes as word chars
    "file -w bad.bin" "file no-flags bad.bin" "file -l -w bad.bin"
    "stdin -w: bad" "stdin no-flags: bad"
    # item 11: directory arg -> wc width fallback 7
    "error: directory"
)

check() {
    local label=$1
    shift # first arg is the name; the REST are passed to both tools
    local bwc_out wc_out bwc_rc wc_rc

    bwc_out=$("$BWC" "$@" 2>/dev/null)
    bwc_rc=$?
    wc_out=$(wc "$@" 2>/dev/null)
    wc_rc=$?

    verdict "$label" "$bwc_out" "$bwc_rc" "$wc_out" "$wc_rc"
}

check_stdin() {
    local label=$1
    shift
    local input=$1
    shift # second arg is the piped input; the REST go to both tools
    local bwc_out wc_out bwc_rc wc_rc

    bwc_out=$(printf "$input" | "$BWC" "$@" 2>/dev/null)
    bwc_rc=$?
    wc_out=$(printf "$input" | wc "$@" 2>/dev/null)
    wc_rc=$?

    verdict "$label" "$bwc_out" "$bwc_rc" "$wc_out" "$wc_rc"
}

verdict() {
    local label=$1 bwc_out=$2 bwc_rc=$3 wc_out=$4 wc_rc=$5
    local expected=false

    if printf '%s\n' "${expected_diffs[@]}" | grep -Fxq "$label"; then
        expected=true
    fi

    if [[ $bwc_out == "$wc_out" && $bwc_rc -eq $wc_rc ]]; then
        if $expected; then
            echo "XPASS: $label (listed as expected diff, but matched)"
            xpass=$((xpass + 1))
        else
            echo "PASS: $label"
            pass=$((pass + 1))
        fi
    else
        if $expected; then
            echo "XFAIL: $label"
            xfail=$((xfail + 1))
        else
            echo "DIFF: $label"
            echo " bwc(rc=$bwc_rc): $bwc_out"
            echo " wc (rc=$wc_rc): $wc_out"
            fail=$((fail + 1))
        fi
    fi
}

# --- generated matrix: fixtures x flag sets ---
fixtures=(testdir/dingus.txt testdir/empty.txt testdir/foobar.txt testdir/utf8test.txt testdir/bad.bin)
flagsets=("-l" "-w" "-c" "-m" "-L" "" "-l -w" "-l -w -c -m -L")

for f in "${fixtures[@]}"; do
    for fl in "${flagsets[@]}"; do
        # intentional word-splitting: $fl unquoted so "-l -w" becomes two args
        check "file ${fl:-no-flags} $(basename "$f")" $fl "$f"
    done
done

# --- multi-file ---
check "multi: -l two files" -l testdir/foobar.txt testdir/dingus.txt
check "multi: all flags two files" -l -w -c -m -L testdir/foobar.txt testdir/dingus.txt
check "multi: -m bad+utf8" -m testdir/bad.bin testdir/utf8test.txt
check "multi: same file twice" testdir/empty.txt testdir/empty.txt
check "multi: good + missing" -l testdir/foobar.txt testdir/missing.txt

# --- error paths ---
check "error: missing file" testdir/missing.txt
check "error: noperm" testdir/noperm.txt
check "error: noperm -l" -l testdir/noperm.txt
check "error: directory" testdir

# --- stdin ---
check_stdin "stdin -l: plain" "ab\ncd\n" -l
check_stdin "stdin no-flags: plain" "ab\ncd\n"
check_stdin "stdin all: plain" "ab\ncd\n" -l -w -c -m -L
check_stdin "stdin -L: utf8" "héllo wörld\n" -L
check_stdin "stdin all: utf8" "héllo wörld\n" -l -w -c -m -L
check_stdin "stdin -m: bad" "\xff\xfe hello" -m
check_stdin "stdin -w: bad" "\xff\xfe hello" -w
check_stdin "stdin no-flags: bad" "\xff\xfe hello"
check_stdin "stdin -l: empty" "" -l
check_stdin "stdin no-flags: empty" ""

# --- summary ---
echo "---"
echo "pass=$pass fail=$fail xfail=$xfail xpass=$xpass"
((fail == 0 && xpass == 0))
