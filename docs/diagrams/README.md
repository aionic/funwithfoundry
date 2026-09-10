# Approved Architecture Renders

These PNGs are approved design documentation, **not live deployment or runtime
evidence**. Rendering does not change any operational status or acceptance gate.

| View | PNG | Locked Mermaid | Nodes | Edges | Boundaries |
| --- | --- | --- | ---: | ---: | ---: |
| Infrastructure and deployment | [PNG](capability-host-deployment-azure-architecture.png) | [Source](capability-host-deployment-azure-architecture.mmd) | 26 | 35 | 12 |
| Document to grounded answer | [PNG](runtime-flow-azure-architecture.png) | [Source](runtime-flow-azure-architecture.mmd) | 20 | 22 | 3 |

Both images are 3840 x 2160 pixels, 16:9 landscape. All node and edge labels,
directions, line styles, boundary labels and memberships come from the approved
Mermaid parser inventory. Layout coordinates are separate; the renderer never
writes Mermaid files. Conceptual or custom components use labeled generic shapes.

## Source Locks

The byte-level SHA-256 locks embedded in the renderer are:

```text
capability-host-deployment:
df09d439f0d4ac75799d3067dd9b3aed5f1b2ea780dab5ba10862f8b6298decf

runtime-flow:
055eca0aca8b27552905b41f29231b8af64cd61226094779cf9238629774aa6e
```

Line-ending changes also invalidate these locks. A changed architecture requires
fresh human approval, never automatic relocking by the renderer.

## Reproduce

Run from the repository root with Node.js and the existing locked dependencies:

```powershell
npm ci --prefix .github
node .github/scripts/render-diagrams.mjs --inventory
node .github/scripts/render-diagrams.mjs
node .github/scripts/render-diagrams.mjs --verify
```

No dependency changes were needed for these exports. The renderer uses Puppeteer
and Mermaid from the existing Mermaid CLI dependency tree. Its temporary HTTP
server binds only to loopback and serves local rendering dependencies. It closes
the server and headless browser on completion or error. There are no Azure calls.

Use Windows with Segoe UI for the same font metrics. Browser version, Node version,
renderer hashes, image hashes, complete source and rendered inventories, routed
coordinates, dimensions and icon provenance are recorded in the
[output manifest](../../.github/scripts/render-diagrams.manifest.json).
Different fonts or browser versions can change image bytes and require another
visual inspection even when the architecture remains identical.

The `--verify` mode does not overwrite images. It re-parses the locked sources,
compares inventories, validates routed source and target ports and node clearance,
decodes both PNGs, checks dimensions and byte hashes, and rejects stale renderer
or visual-inspection records. It is not a live infrastructure test.

## Official Artwork

The icons are original, unmodified SVG files from the Microsoft
[Azure architecture icon collection](https://learn.microsoft.com/en-us/azure/architecture/icons/),
[V24 download](https://arch-center.azureedge.net/icons/Azure_Public_Service_Icons_V24.zip).
Each local file's SHA-256 is checked against its original archive entry. Images
are embedded with preserved aspect ratio, without recoloring, rotation or cropping.

To restore these selected assets from the official download:

```powershell
& .github/scripts/render-diagrams.assets.ps1
```

The [asset manifest](../../.github/scripts/render-diagrams.assets.json) records the
download URL, archive hash, exact archive entries and original SVG hashes.
Microsoft permits architectural documentation use and reserves all other rights;
see the terms on the official collection page.

## Inspection

Both final PNGs were opened using `view_image`. Readability, cropping, official
artwork, boundaries, directional connections and runtime failure branches were
inspected. The topology is intentionally denser than the application-flow view;
the complete 35-edge approved contract is retained.

The [visual-inspection record](../../.github/scripts/render-diagrams.qa.json) is
bound to the inspected PNG hashes. It must not be updated automatically after a
changed render: inspect the actual new PNGs first. Reproduction and automated
inventory checks do not replace visual inspection.
