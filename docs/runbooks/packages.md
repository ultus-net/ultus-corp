# Package locks

The lock records the exact NEVRAs the role image installed. The next build
installs from the lock, so a rebuild cannot silently pick a newer package.

## Resolve and record the dns lock

Run from the repository root, 2026-11-26:

```bash
bash build/package-lock.sh resolve dns
bash tests/test-packages.sh
bash -c '. build/common.sh && build_role dns'
podman run --rm localhost/ultus-corp/dns:local rpm -qa --qf '%{NAME}-%{EVR}.%{ARCH}\n' \
  | grep -v '^gpg-pubkey-' | sort > run/dns-installed.txt
diff run/dns-installed.txt manifests/packages-dns.lock
```

Expected: the test prints eight `ok` lines, and the diff prints nothing.

The first command builds the image from `manifests/packages-dns.txt` and writes
`manifests/packages-dns.lock`. The third rebuilds with the lock as the install
list. The diff proves the lock is what the image contains.

## Adding or changing a package

1. Edit `manifests/packages-<role>.txt`.
2. Delete `manifests/packages-<role>.lock`.
3. Run the sequence above again.
4. Commit both the manifest and the lock in one change.
