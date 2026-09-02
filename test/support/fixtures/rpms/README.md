# RPM parser fixtures

Small RPM packages exercised by the pure-Elixir parser tests
(`DarkZenith.Rpm`), plus the `createrepo_c` metadata generated from them,
which serves as the differential-parity reference (DESIGN.md: RPM Parsing),
and one real-world package for the end-to-end upload test.

| File                         | What it is                                                                   |
| ---------------------------- | ---------------------------------------------------------------------------- |
| `dz-fixture-v4.rpm`          | Format v4 binary package with every dependency class, files, changelogs      |
| `dz-fixture-v6.rpm`          | The same spec built as format v6 (`--define "_rpmformat 6"`)                 |
| `dz-fixture-v4.src.rpm`      | Source package built from the same spec (`SOURCEPACKAGE = 1`)                |
| `dz-minimal-v4.rpm`          | Minimal v4 package with no optional fields, deps, files, or changelogs       |
| `paladin-0.1.0-1.x86_64.rpm` | Real-world unsigned x86_64 binary package built outside rpmbuild (see below) |
| `dz-fixture.spec`            | Spec used to build the three `dz-fixture` artifacts                          |
| `dz-minimal.spec`            | Spec used to build `dz-minimal-v4.rpm`                                       |
| `createrepo_c/*.xml`         | Uncompressed `primary`/`filelists`/`other` XML from `createrepo_c 1.2.1`     |

Built on Fedora 43 with `rpm-build 6.0.1`. To regenerate (values baked into
tests — header offsets, checksums, sizes — change if you do):

```bash
export SOURCE_DATE_EPOCH=1787200000
TOP="$(mktemp -d)/rpmbuild"
mkdir -p "${TOP}/SPECS" && cp dz-*.spec "${TOP}/SPECS/"
common=(--define "_topdir ${TOP}" --define "_buildhost dz-fixture-builder"
        --define "use_source_date_epoch_as_buildtime 1")
rpmbuild "${common[@]}" --define "_rpmformat 4" -bb "${TOP}/SPECS/dz-fixture.spec"
rpmbuild "${common[@]}" --define "_rpmformat 6" -bb "${TOP}/SPECS/dz-fixture.spec"
rpmbuild "${common[@]}" --define "_rpmformat 4" -bs "${TOP}/SPECS/dz-fixture.spec"
rpmbuild "${common[@]}" --define "_rpmformat 4" -bb "${TOP}/SPECS/dz-minimal.spec"
createrepo_c --simple-md-filenames <dir-with-the-two-binary-noarch-rpms>
```

Malformed and weak-digest variants are not stored: parser tests derive them
by byte-patching these valid files (see `DarkZenith.RpmFixtures`).

`paladin-0.1.0-1.x86_64.rpm` is a vendored artifact rather than a built one:
an unsigned x86_64 binary package with a gzip-compressed cpio payload and no
`RPMVERSION` tag (so not produced by `rpmbuild`), exercised by the
end-to-end tests under `test/end_to_end/`. It is not regenerated.
