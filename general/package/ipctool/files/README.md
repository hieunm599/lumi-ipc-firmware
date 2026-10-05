# Embedded MIPS32 ipctool binary

Source: OpenIPC/ipctool rolling `latest` release, commit
`2082b3270d4b878395ab626d1fcbce25a8087f1b`, asset `ipctool-mips32`.
The asset is a statically linked MIPS32r2 little-endian musl executable.
SHA-256: `1b9298a565e2eff6e2f0d15321dbcf1bb59cc9585a247bcfbb99315bfa949dff`.

This prebuilt diagnostic tool avoids downloading the `ipctool` plugin at runtime.
The current upstream release does not yet identify Ingenic T33 or SC4336, so its
SoC/sensor detection and T33-specific GPIO/padmux commands remain limited.
