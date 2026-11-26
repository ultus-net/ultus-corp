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
            [ -n "$arg_base" ] || { echo "FROM uses \${BASE} with no ARG BASE in $file"; status=1; continue; }
            ref="$arg_base"
        fi

        if [ "$ref" != "$expected" ]; then
            echo "Base mismatch in $file: expected '$expected', found '$ref'"
            status=1
        fi
    done
    return $status
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
