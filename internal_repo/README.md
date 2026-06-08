# internal_repo/

Pre-built Windows R package binaries for air-gapped HPC environments where
CRAN is not accessible. Used by `setup/install_packages.R` as a local CRAN
mirror when `USE_INTERNAL_REPO=true`.

**Only packages unavailable on CRAN belong here.** CRAN-available packages
(including most HADES packages) are handled directly by renv — do not
duplicate them here.

## Current binaries (R 4.5, Windows)

| Package | Version | Why it's here |
|---------|---------|---------------|
| ETLSyntheaBuilder | 2.1 | Not on CRAN — OHDSI GitHub only |

## Adding a package

Before adding a binary, verify the package is not on CRAN:

```r
available.packages(repos = "https://cloud.r-project.org")["MyPackage", ]
# Returns NA row → not on CRAN → add binary here
# Returns valid row → on CRAN → let renv handle it, do not add here
```

If the package is genuinely not on CRAN, download the Windows binary from
any OS:

```r
options(repos = c(CRAN = "https://cloud.r-project.org"))
download.packages(
  "PackageName",
  destdir = "internal_repo/bin/windows/contrib/4.5",
  type    = "win.binary"
)
```

Then commit the `.zip` and update this README.
