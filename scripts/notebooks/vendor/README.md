# Notebook browser dependencies

Quarto 1.10.19 adds RequireJS 2.3.6 and jQuery 3.5.1 CDN tags whenever a notebook
has HTML output, including plain tables. `scripts.notebooks.assets` replaces
those tags with these local files and their checked SHA-384 integrity values.
The site and its widgets can therefore be checked with outside network access
blocked. No downloads occur during rendering.

- `require-2.3.6.js`: unminified source from the official
  [RequireJS 2.3.6 release](https://github.com/requirejs/requirejs/tree/2.3.6),
  byte-identical to `require.js` in the integrity-verified npm release archive.
  License: `LICENSE.requirejs` (MIT or BSD).
- `jquery-3.5.1.min.js`: `dist/jquery.min.js` from the integrity-verified
  [jQuery 3.5.1 npm release](https://www.npmjs.com/package/jquery/v/3.5.1), matching
  the SRI value used by Quarto. License: `LICENSE.jquery` (MIT).

The CDN-generated RequireJS minification downloaded during validation had a hash
different from both SRI values in Quarto's generated tag. The unminified release
file avoids dependence on changing CDN minification. Upgrade versions and
`assets.py` integrity values together, after verifying the upstream release and
running the offline browser checks.
