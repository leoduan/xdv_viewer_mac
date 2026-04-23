# LaTeX XDV Viewer

A native macOS viewer for `.tex` and `.xdv` files, with a normal app menu and in-window rendering controls.

It works by:

1. accepting either a `.tex` or `.xdv` input
2. compiling `.tex` inputs with `latexmk`
3. either:
   - producing `.xdv` and converting it to SVG pages with `dvisvgm`, or
   - producing PDF and displaying it with native `PDFView`
4. displaying the result in a native macOS window with navigation and zoom controls

## Features

- Open `.tex` or `.xdv` files from the app or the command line
- Auto-reload when the input file changes
- Automatic `latexmk` compilation for `.tex` inputs
- Better support for bibliography and reference reruns on `.tex` inputs
- Render backend dropdown:
  - `SVG`: XDV + SVG
  - `PDF`: native `PDFView` (default)
- Figure dropdown:
  - `Show`: normal rendering
  - `Hide`: draft-mode graphics using `\Gin@drafttrue` (default)
- SyncTeX target dropdown:
  - `Cursor` (default)
  - `Code`
- Page jump box
- Previous/next page navigation
- Single-page and two-page viewing modes
- Zoom in/out
- Fit-to-width mode
- SyncTeX reverse lookup via Command-click on a page
- Standard app menus for `Open`, `Close`, and `Quit`
- LaTeX build artifacts for `.tex` inputs are kept in a hidden `.xdv-viewer-build` folder beside the source file
- Optional direct XDV-to-SVG rendering without a PDF step
- SVG output uses path outlines for more reliable math and symbol rendering

## Run

```bash
swiftc -module-cache-path .build/module-cache Sources/main.swift -o .build/xdv-native-viewer -framework AppKit -framework WebKit -framework PDFKit
.build/xdv-native-viewer
```

Then use `File > Open...` inside the app.

You can still launch a file directly from the command line:

```bash
.build/xdv-native-viewer /path/to/file.tex
```

You can also choose an initial backend from the command line:

```bash
.build/xdv-native-viewer --pdf-native /path/to/file.tex
```

Or force SVG mode:

```bash
.build/xdv-native-viewer --xdv-svg /path/to/file.tex
```

Optional startup flags:

- `--pdf-native`: start in PDF mode
- `--xdv-svg`: start in SVG mode
- `--hide-figures`: start with figures hidden
- `--show-figures`: start with figures visible
- `--synctex-cursor`: start with Cursor as reverse-lookup target
- `--synctex-code`: start with VS Code as reverse-lookup target
- `--reverse-command "..."`: override the editor dropdown with a custom command template

## Browser fallback

If you still want the old browser-based viewer:

```bash
python3 viewer.py /path/to/file.tex
```

## Keyboard shortcuts

- `Left`: previous page
- `Right`: next page
- `+` / `=`: zoom in
- `-`: zoom out
- `0`: fit width
- `1`: single-page view
- `2`: two-page view
- `R`: reload
- Command-click on a page: reverse lookup

## Sample document

Launch the app and open the sample:

```bash
.build/xdv-native-viewer sample.tex
```
