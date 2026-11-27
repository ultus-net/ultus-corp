#!/usr/bin/env bash
# Pure functions for static checks on the lab tree.
# Each returns 0 when clean, 1 with a one-line reason on stdout.

check_base_pin() {
    local expected_file="$1"
    shift
    local expected
    expected=$(head -n 1 "$expected_file" | tr -d '[:space:]')
    [ -n "$expected" ] || { echo "empty expected file: $expected_file"; return 1; }

    local file status=0
    for file in "$@"; do
        [ -r "$file" ] || { echo "File not readable: $file"; status=1; continue; }

        local arg_base ref
        arg_base=$(sed -n 's/^ARG[[:space:]]*BASE=//p' "$file" | tail -n 1)
        ref=$(sed -n 's/^FROM[[:space:]]*//p' "$file" \
              | grep -v '^scratch' | awk '{print $1}' | tail -n 1)

        if [ -z "$ref" ]; then
            echo "No FROM found in $file"
            status=1
            continue
        fi

        if [ "$ref" = '${BASE}' ]; then
            # A Dockerfile may declare ARG BASE with no default, because the
            # build passes the pinned digest. A declared default must match.
            grep -qE '^ARG[[:space:]]+BASE(=[^[:space:]]*)?$' "$file" \
                || { echo "FROM uses \${BASE} with no ARG BASE in $file"; status=1; continue; }
            if [ -z "$arg_base" ]; then
                continue
            fi
            ref="$arg_base"
        fi

        if [ "$ref" != "$expected" ]; then
            echo "Base mismatch in $file: expected '$expected', found '$ref'"
            status=1
        fi
    done
    return $status
}

# A role image must layer on the core, never on the upstream base.
check_role_froms_core() {
    local status=0 file ref
    for file in "$@"; do
        [ -r "$file" ] || { echo "File not readable: $file"; status=1; continue; }
        if ! grep -qE '^ARG[[:space:]]+CORE(=[^[:space:]]*)?$' "$file"; then
            echo "No ARG CORE in $file"
            status=1
            continue
        fi
        ref=$(sed -n 's/^FROM[[:space:]]*//p' "$file" \
              | grep -v '^scratch' | awk '{print $1}' | tail -n 1)
        if [ "$ref" != '${CORE}' ]; then
            echo "$file does not build FROM \${CORE}: found '$ref'"
            status=1
        fi
    done
    return $status
}

# The core reference must name a digest, because a tag can be moved.
check_core_ref() {
    local file="$1" ref
    [ -r "$file" ] || { echo "File not readable: $file"; return 1; }
    ref=$(head -n 1 "$file" | tr -d '[:space:]')
    if [[ ! "$ref" =~ @sha256:[0-9a-f]{64}$ ]]; then
        echo "Core ref is not digest pinned: ${ref:-empty}"
        return 1
    fi
    return 0
}

# Containerfile.core names the base as an argument, so the pin is enforced
# where the argument is supplied.
check_core_build_arg() {
    local file="$1"
    [ -r "$file" ] || { echo "File not readable: $file"; return 1; }
    if ! grep -qF -- '--build-arg BASE="$(base_ref)"' "$file"; then
        echo "No --build-arg BASE=\"\$(base_ref)\" in $file"
        return 1
    fi
    return 0
}

check_manifest_one_per_line() {
    local status=0 file line_num line trimmed
    for file in "$@"; do
        [ -r "$file" ] || { echo "File not readable: $file"; status=1; continue; }
        line_num=0
        while IFS= read -r line; do
            line_num=$((line_num + 1))
            trimmed="${line#"${line%%[![:space:]]*}"}"
            [ -z "$trimmed" ] && continue
            [[ "$trimmed" == \#* ]] && continue
            if [[ "$trimmed" == *[[:space:]]* ]]; then
                echo "Multiple packages on line $line_num in $file"
                status=1
            fi
        done < "$file"
    done
    return $status
}

check_no_secret_patterns() {
    local status=0 path
    for path in "$@"; do
        [ -e "$path" ] || { echo "Path missing: $path"; status=1; continue; }
        if grep -rIE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$path" >/dev/null 2>&1; then
            echo "Private key material in $path"
            status=1
        fi
        if grep -rIE -- 'AGE-SECRET-KEY-1' "$path" >/dev/null 2>&1; then
            echo "Age secret key in $path"
            status=1
        fi
        if grep -rIE -- '^[[:space:]]*PrivateKey[[:space:]]*=' "$path" >/dev/null 2>&1; then
            echo "WireGuard private key in $path"
            status=1
        fi
        if grep -rIE -- 'lab-secrets/' "$path" >/dev/null 2>&1; then
            echo "Reference to lab-secrets/ in $path"
            status=1
        fi
    done
    return $status
}

check_no_install_media() {
    local status=0 path hit
    for path in "$@"; do
        [ -e "$path" ] || { echo "Path missing: $path"; status=1; continue; }
        hit=$(find "$path" -type f \( -name '*.iso' -o -name '*.vhd' -o -name '*.qcow2' -o -name '*.wim' \) 2>/dev/null \
              | grep -vE '(^|/)run/' | head -n 1)
        if [ -n "$hit" ]; then
            echo "Install media in tree: $hit"
            status=1
        fi
    done
    return $status
}

check_role_records() {
    local status=0 path file field
    local -a files=()
    for path in "$@"; do
        if [ -d "$path" ]; then
            while IFS= read -r file; do files+=("$file"); done < <(find "$path" -maxdepth 1 -type f -name '*.md')
        elif [ -r "$path" ]; then
            files+=("$path")
        else
            echo "Role record missing: $path"
            status=1
        fi
    done

    for file in "${files[@]}"; do
        for field in "Linux mechanism" "Windows concept" "Where it breaks" "Proof"; do
            if ! grep -q "^## $field" "$file"; then
                echo "Missing '$field' in $file"
                status=1
            fi
        done
    done
    return $status
}
