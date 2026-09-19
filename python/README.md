# zals (Python wrapper)

A thin Python wrapper around the [zals](https://github.com/kksat/zals) Zig
Ansible Language Server. The wheel bundles the prebuilt `zals` binary for the
current platform and exposes it as the `zals` console script.

```sh
pip install zals
zals --version
```

The wrapper does not reimplement anything: it locates the bundled binary and
executes it, forwarding all arguments and stdio. Point your LSP client at
`zals --stdio` with `ansible` as the document language.

See the [main repository](https://github.com/kksat/zals) for documentation,
source, and the release process.

## License

GPL-3.0-only.