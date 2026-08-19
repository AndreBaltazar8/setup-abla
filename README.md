# setup-abla

`setup-abla` installs a released Abla toolchain in GitHub Actions without
building the compiler from source. It verifies the release checksum, reuses the
runner tool cache, adds `ablac` to `PATH`, and exposes `ABLA_HOME` and
`ABLA_SYSROOT` to later steps.

```yaml
steps:
  - uses: actions/checkout@v6
  - uses: AndreBaltazar8/setup-abla@v1
    with:
      version: '0.2.10'
  - run: ablac build app.ab -o build/app
```

Pin the action to a full commit SHA when the workflow needs an immutable supply
chain. The moving `v1` tag is provided for convenient updates.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `version` | `0.2.10` | Exact Abla release, without the leading `v`. |
| `token` | `github.token` | Token used for public GitHub release downloads. |
| `install-dependencies` | `true` | Install missing host build prerequisites on Ubuntu or Homebrew packages on macOS. |

## Outputs

| Output | Meaning |
| --- | --- |
| `version` | Exact installed compiler version. |
| `path` | Absolute toolchain root. |
| `cache-hit` | `true` when the matching toolchain was already cached on the runner. |

Linux x86-64 uses the portable Abla/LLVM/Binaryen release archive and the
runner's ordinary glibc development files; on a minimal Ubuntu runner the
action installs `build-essential` when needed. Intel and Apple Silicon macOS
use their native precompiled compiler and Homebrew-provided native libraries.
Windows and Linux ARM64 fail with an explicit unsupported-platform message
until Abla publishes those compiler artifacts.

## Security

The action accepts only exact semantic versions, downloads over HTTPS from the
official `AndreBaltazar8/ablac` release, verifies the accompanying SHA-256
checksum, validates archive paths, and installs under `RUNNER_TOOL_CACHE`.
Release tags and action tags are separate: pinning this action by commit SHA is
the strongest workflow policy.

## License

MIT
