# App icon source

## Artwork provenance

`oc-logo-1c-blue-RGB.svg` is the official ownCloud logo, committed unmodified from
the ownCloud press-resources archive:

* Download: <https://owncloud.com/ownCloud_logo.zip>
  (redirects to `owncloud.com/wp-content/uploads/press_downloads/ownCloud_logo.zip`)
* Path inside the archive:
  `corporate-resources/ownCloud/ownCloud/RGB/oc-logo-1c-blue-RGB.svg`
* SHA-256: `384db36d680edf7c8e632afae7cae3995218c52e76d658e014223483b56028c0`

The ownCloud name and logo are trademarks of ownCloud GmbH. The file is included
here only to build this application's own icon.

## Which part of the logo the icon uses

The SVG contains nine `<path>` elements sharing a single `#041E42` fill:

| Paths | Content |
|---|---|
| 0–7 | the "ownCloud" wordmark |
| 8 | the cloud mark on its own |

The icon uses **path 8 only**. The wordmark is dropped deliberately — the Finder
sidebar renders sync roots at 16 px, where lettering turns to mush. The mark is
laid dark-blue on a white squircle so it reads in both light and dark Finder
sidebars.

## Regenerating

```sh
make icons        # from the repository root
```

That runs `make-icon.swift`, which writes the ten PNGs and `Contents.json` into
`Resources/Assets.xcassets/AppIcon.appiconset/`. The generated PNGs **are
committed**, so this only needs re-running when the artwork or the sizing
constants in the script change; a clean `git diff` after running it confirms the
committed icons are current.

The script measures the cloud's bounding box from the path data rather than
hardcoding it, so refreshing the upstream SVG does not silently mis-centre the
mark. It fails loudly if path 8 stops looking like the wide cloud mark.

## Two constraints worth knowing before changing the script

* **`qlmanage -t` cannot rasterize this.** It forces square output *and*
  composites onto opaque white, which silently destroys the squircle's
  transparent corners. The script draws through `NSImage` →
  `NSBitmapImageRep` instead, which preserves alpha and needs no Homebrew
  tooling (ImageMagick and rsvg-convert are not assumed to be installed).
* **The two `.appex` targets need `ASSETCATALOG_COMPILER_APPICON_NAME` set
  explicitly** in `project.yml`. The app target gets it for free; without it on
  the extensions, their `Contents/Resources` builds out empty and no icon ships.
