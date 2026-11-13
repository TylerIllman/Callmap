# Changelog

## Unreleased

- Duplicate callers and callees are drawn once, and functions outside the workspace are hidden by default (`hide_external`).
- Shorter footer. Added `examples/demo.py`, a screenshot, a banner and badges to the README.
- Renamed from `callgraph.nvim` to `callmap.nvim` (module `callmap`, command `:Callmap`, highlight groups `Callmap*`).

## 0.1.0

- Initial release: left-to-right call graph with callers, callees and a source preview, lazy loading,
  expand all, recursion detection, configurable size and mappings.
