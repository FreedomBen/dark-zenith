Name:           dz-fixture
Epoch:          2
Version:        1.2.3
Release:        4
Summary:        Dark Zenith parser fixture package — ünïcode ok
License:        MIT
URL:            https://example.com/dz-fixture
Group:          Development/Testing
Vendor:         Dark Zenith Test Vendor
BuildArch:      noarch

Requires:       dz-lib >= 1.0
Requires:       dz-data
Requires(pre):  dz-pre-tool
Requires(post): dz-post-tool
Requires:       (dz-alt-a or dz-alt-b)
Recommends:     dz-nice >= 2.0
Suggests:       dz-maybe
Supplements:    dz-parent
Enhances:       dz-extra = 3.1
Provides:       dz-capability = 9.9
Provides:       dz-fixture-alias
Conflicts:      dz-old < 1.0
Obsoletes:      dz-legacy <= 0.5

%description
Fixture package for the Dark Zenith pure-Elixir RPM parser.
It carries every dependency class, files, and changelog entries.

Second paragraph with a tab:	and ünïcode.

%prep
%build
%install
mkdir -p %{buildroot}/usr/share/dz-fixture
mkdir -p %{buildroot}/usr/bin
echo "hello dark zenith" > %{buildroot}/usr/share/dz-fixture/data.txt
cat > %{buildroot}/usr/bin/dz-fixture <<'EOF'
#!/bin/sh
echo dz-fixture
EOF
chmod 0755 %{buildroot}/usr/bin/dz-fixture

%files
%dir /usr/share/dz-fixture
/usr/share/dz-fixture/data.txt
/usr/bin/dz-fixture

%changelog
* Tue Aug 25 2026 Fixture Author <fixtures@example.com> - 2:1.2.3-4
- Second changelog entry with ünïcode

* Mon Aug 24 2026 Fixture Author <fixtures@example.com> - 2:1.2.2-1
- First changelog entry
