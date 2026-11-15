# Vendored Three.js

Three.js **r0.187.0** (MIT, see `LICENSE`), copied from the `three` npm package
(`build/three.module.js`, `build/three.core.js`, `examples/jsm/controls/OrbitControls.js`).

Changes from upstream (nothing else is edited):

1. Each file is minified with esbuild 0.28.2 (`--minify --format=esm`, no bundling), because
   the package has no minified module build in this release.
2. In `OrbitControls.js` the import `from "three"` is rewritten to `from "./three.module.js"`.
   This avoids an inline `<script type="importmap">`, which the page's Content-Security-Policy
   (`script-src 'self'`) would block.

To upgrade: download the new `three` tarball, repeat the two steps, update the version above,
and run the tests (`pytest tests/test_viewer.py`) and a look in a browser.
