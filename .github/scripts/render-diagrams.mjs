import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer';
import { icons, layouts } from './render-diagrams.layout.mjs';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(scriptDirectory, '../..');
const contracts = [
  {
    slug: 'capability-host-deployment',
    sha256: 'df09d439f0d4ac75799d3067dd9b3aed5f1b2ea780dab5ba10862f8b6298decf',
    title: 'Private infrastructure & deployment',
  },
  {
    slug: 'runtime-flow',
    sha256: '055eca0aca8b27552905b41f29231b8af64cd61226094779cf9238629774aa6e',
    title: 'Document to grounded answer',
  },
];

const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');

async function lockedSource(contract) {
  const filename = path.join(root, 'docs/diagrams', `${contract.slug}-azure-architecture.mmd`);
  const bytes = await readFile(filename);
  assert.equal(digest(bytes), contract.sha256, `Approved source changed: ${filename}`);
  return bytes.toString('utf8');
}

async function startAssetServer() {
  const packageRoot = path.resolve(root, '.github/node_modules');
  const server = createServer(async (request, response) => {
    try {
      const pathname = new URL(request.url, 'http://localhost').pathname;
      if (pathname === '/') {
        response.setHeader('Content-Type', 'text/html');
        response.end('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
        return;
      }
      const filename = path.resolve(packageRoot, `.${decodeURIComponent(pathname)}`);
      if (!filename.startsWith(`${packageRoot}${path.sep}`)) {
        response.writeHead(403).end();
        return;
      }
      response.setHeader('Content-Type', 'text/javascript');
      response.end(await readFile(filename));
    } catch {
      response.writeHead(404).end();
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { server, url: `http://127.0.0.1:${server.address().port}` };
}

async function inventory(page, source) {
  return page.evaluate(async (text) => {
    const { default: mermaid } = await import('/mermaid/dist/mermaid.esm.min.mjs');
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' });
    const diagram = await mermaid.mermaidAPI.getDiagramFromText(text);
    const groups = diagram.db.getSubGraphs();
    const groupIds = new Set(groups.map((group) => group.id));
    const clean = (label) => {
      const element = document.createElement('div');
      element.innerHTML = label.replace(/<br\s*\/?\s*>/gi, '\n');
      return element.textContent;
    };
    return {
      nodes: [...diagram.db.getVertices().values()].filter((node) => !groupIds.has(node.id))
        .map((node) => ({ id: node.id, label: clean(node.text), classes: node.classes })),
      edges: diagram.db.getEdges().map((edge) => ({
        id: edge.id, source: edge.start, target: edge.end, label: clean(edge.text),
        arrow: edge.type, stroke: edge.stroke,
      })),
      boundaries: groups.map((group) => ({ id: group.id, label: clean(group.title), children: group.nodes })),
    };
  }, source);
}

async function loadIcons() {
  const manifest = JSON.parse((await readFile(path.join(scriptDirectory, 'render-diagrams.assets.json'), 'utf8')).replace(/^\uFEFF/, ''));
  const images = {};
  for (const [name, filename] of Object.entries(icons)) {
    const provenance = manifest.assets.find((asset) => asset.file.endsWith(`/${filename}`));
    assert.ok(provenance, `Missing provenance: ${filename}`);
    const bytes = await readFile(path.join(root, provenance.file));
    assert.equal(digest(bytes), provenance.sha256, `Official artwork changed: ${filename}`);
    images[name] = `data:image/svg+xml;base64,${bytes.toString('base64')}`;
  }
  return { images, manifest };
}

async function draw(page, contract, parsed, images) {
  const layout = layouts[contract.slug];
  assert.deepEqual(Object.keys(layout.nodes).sort(), parsed.nodes.map((node) => node.id).sort(), 'Node inventory mismatch');
  assert.deepEqual(Object.keys(layout.boundaries).sort(), parsed.boundaries.map((group) => group.id).sort(), 'Boundary inventory mismatch');
  return page.evaluate(async ({ contract, parsed, layout, images }) => {
    document.body.replaceChildren();
    const style = document.createElement('style');
    style.textContent = `
      * { box-sizing: border-box; }
      body { margin: 0; background: #fff; font-family: 'Segoe UI', sans-serif; color: #192b38; }
      #sheet { position: relative; width: 3840px; height: 2160px; overflow: hidden; background: #fff; }
      .heading { position: absolute; left: 60px; top: 35px; margin: 0; font-size: 52px; font-weight: 600; }
      .status { position: absolute; right: 60px; top: 56px; font-size: 26px; color: #64501e; }
      .boundary { position: absolute; border: 2px solid #a9c6d8; border-radius: 6px; background: #f8fbfe; }
      .boundary.region { background: #f5f9fd; }
      .boundary.network { background: #f3faf9; border-color: #76aaa5; }
      .boundary.subnet { background: #fff; border: 2px dashed #9cbeba; }
      .boundary.control { background: #fffaf0; border-color: #d5c39a; }
      .boundary-title { padding: 14px 20px; font-size: 27px; font-weight: 600; line-height: 1.22; }
      .node { position: absolute; border: 2px solid #819db0; border-radius: 6px; background: #fff; display: flex; align-items: center; padding: 16px 20px; gap: 16px; }
      .node-copy { min-width: 0; font-size: 27px; line-height: 1.26; white-space: pre-line; overflow-wrap: normal; }
      .node-copy::first-line { font-weight: 600; }
      .node img { width: 58px; height: 58px; object-fit: contain; flex: 0 0 58px; }
      .icon-stack { display: flex; flex-direction: column; gap: 4px; }
      .icon-stack img { width: 28px; height: 28px; flex-basis: 28px; }
      .node.legend { border: 0; background: #f4f6f7; padding: 22px 24px; }
      .node.legend .node-copy { font-size: 25px; line-height: 1.32; }
      .edge-label { position: absolute; font-size: 24px; line-height: 1.22; padding: 7px 10px; text-align: center; background: #fff; border-radius: 3px; color: #244963; }
      .edge-label.secondary { color: #755923; }
      svg.wires { position: absolute; inset: 0; width: 3840px; height: 2160px; }
    `;
    document.head.append(style);
    const sheet = document.createElement('main');
    sheet.id = 'sheet';
    document.body.append(sheet);
    const heading = document.createElement('h1');
    heading.className = 'heading';
    heading.textContent = contract.title;
    sheet.append(heading);
    const status = document.createElement('div');
    status.className = 'status';
    status.textContent = 'APPROVED DESIGN  /  NOT LIVE EVIDENCE';
    sheet.append(status);
    const setBox = (element, rectangle) => Object.assign(element.style, {
      left: `${rectangle.x}px`, top: `${rectangle.y}px`, width: `${rectangle.width}px`, height: `${rectangle.height}px`,
    });
    const elements = {};
    const groupById = Object.fromEntries(parsed.boundaries.map((group) => [group.id, group]));
    const depth = (identifier) => {
      const parent = parsed.boundaries.find((group) => group.children.includes(identifier));
      return parent ? 1 + depth(parent.id) : 0;
    };
    const headerObstacles = [];
    for (const group of [...parsed.boundaries].sort((left, right) => depth(left.id) - depth(right.id))) {
      const rectangle = layout.boundaries[group.id];
      const element = document.createElement('section');
      element.className = `boundary ${rectangle.tone}`;
      element.dataset.boundary = JSON.stringify(group);
      setBox(element, rectangle);
      const title = document.createElement('div');
      title.className = 'boundary-title';
      title.textContent = group.label;
      element.append(title);
      sheet.append(element);
      elements[group.id] = element;
      headerObstacles.push({ x: rectangle.x, y: rectangle.y, width: rectangle.width, height: title.offsetHeight + 4 });
    }
    const namespace = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(namespace, 'svg');
    svg.classList.add('wires');
    svg.innerHTML = `<defs>
      <marker id="solid-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="10" markerHeight="10" orient="auto-start-reverse" markerUnits="userSpaceOnUse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#28648a"/></marker>
      <marker id="secondary-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="10" markerHeight="10" orient="auto-start-reverse" markerUnits="userSpaceOnUse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#947437"/></marker>
    </defs>`;
    sheet.append(svg);
    for (const node of parsed.nodes) {
      const rectangle = layout.nodes[node.id];
      const element = document.createElement('article');
      element.className = `node ${node.id === 'legend' ? 'legend' : ''}`;
      element.dataset.node = JSON.stringify(node);
      setBox(element, rectangle);
      if (rectangle.icon) {
        const names = Array.isArray(rectangle.icon) ? rectangle.icon : [rectangle.icon];
        const holder = document.createElement('div');
        holder.className = names.length > 1 ? 'icon-stack' : 'icon';
        for (const name of names) {
          const image = document.createElement('img');
          image.src = images[name];
          image.alt = '';
          image.dataset.officialIcon = name;
          holder.append(image);
        }
        element.append(holder);
      }
      const copy = document.createElement('div');
      copy.className = 'node-copy';
      copy.textContent = node.label;
      element.append(copy);
      sheet.append(element);
      elements[node.id] = element;
    }
    await document.fonts.ready;
    await Promise.all([...sheet.querySelectorAll('img')].map((image) => image.decode()));
    const failures = [];
    const intersects = (first, second, gap = 0) => first.x < second.x + second.width + gap && first.x + first.width + gap > second.x && first.y < second.y + second.height + gap && first.y + first.height + gap > second.y;
    const contains = (outer, inner) => inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height;
    const nodeBoxes = Object.entries(layout.nodes).map(([id, rectangle]) => ({ id, ...rectangle }));
    for (const node of parsed.nodes) {
      const element = elements[node.id];
      const copy = element.querySelector('.node-copy');
      if (copy.scrollWidth > copy.clientWidth + 1 || copy.offsetHeight > element.clientHeight - 24) failures.push(`Text overflow: ${node.id}`);
      for (const other of nodeBoxes) {
        if (node.id < other.id && intersects(layout.nodes[node.id], other, 12)) failures.push(`Nodes overlap: ${node.id}, ${other.id}`);
      }
    }
    for (const group of parsed.boundaries) {
      for (const child of group.children) {
        if (!contains(layout.boundaries[group.id], layout.nodes[child] ?? layout.boundaries[child])) failures.push(`Boundary membership: ${group.id}/${child}`);
      }
      for (const node of parsed.nodes) {
        const descendants = (identifier) => groupById[identifier]?.children.flatMap((child) => groupById[child] ? descendants(child) : [child]) ?? [];
        if (!descendants(group.id).includes(node.id) && intersects(layout.boundaries[group.id], layout.nodes[node.id])) failures.push(`Unrelated boundary overlap: ${group.id}/${node.id}`);
      }
    }
    if (failures.length) throw new Error(failures.join('\n'));

    const grid = 20;
    const columns = 192;
    const rows = 108;
    const usage = new Map();
    const port = (rectangle, destination) => {
      const center = { x: rectangle.x + rectangle.width / 2, y: rectangle.y + rectangle.height / 2 };
      const delta = { x: destination.x + destination.width / 2 - center.x, y: destination.y + destination.height / 2 - center.y };
      if (Math.abs(delta.x) > Math.abs(delta.y)) {
        const east = delta.x >= 0;
        const border = east ? rectangle.x + rectangle.width : rectangle.x;
        const vertical = Math.round(center.y / grid) * grid;
        return { face: [border, vertical], anchor: [east ? Math.ceil((border + 24) / grid) * grid : Math.floor((border - 24) / grid) * grid, vertical] };
      }
      const south = delta.y >= 0;
      const border = south ? rectangle.y + rectangle.height : rectangle.y;
      const horizontal = Math.round(center.x / grid) * grid;
      return { face: [horizontal, border], anchor: [horizontal, south ? Math.ceil((border + 24) / grid) * grid : Math.floor((border - 24) / grid) * grid] };
    };
    const blockedGrid = (obstacles) => {
      const blocked = new Uint8Array(columns * rows);
      for (const rectangle of obstacles) {
        const left = Math.max(1, Math.ceil((rectangle.x - 12) / grid));
        const right = Math.min(columns - 2, Math.floor((rectangle.x + rectangle.width + 12) / grid));
        const top = Math.max(7, Math.ceil((rectangle.y - 12) / grid));
        const bottom = Math.min(rows - 2, Math.floor((rectangle.y + rectangle.height + 12) / grid));
        for (let vertical = top; vertical <= bottom; vertical++) {
          for (let horizontal = left; horizontal <= right; horizontal++) blocked[vertical * columns + horizontal] = 1;
        }
      }
      return blocked;
    };
    const route = (startPort, endPort, blocked) => {
      const start = startPort.anchor[1] / grid * columns + startPort.anchor[0] / grid;
      const end = endPort.anchor[1] / grid * columns + endPort.anchor[0] / grid;
      const previous = new Int32Array(columns * rows).fill(-1);
      const score = new Float64Array(columns * rows).fill(Infinity);
      const visited = new Uint8Array(columns * rows);
      const heap = [];
      const push = (entry) => {
        heap.push(entry);
        let index = heap.length - 1;
        while (index > 0) {
          const parent = (index - 1) >> 1;
          if (heap[parent].priority <= entry.priority) break;
          heap[index] = heap[parent];
          index = parent;
        }
        heap[index] = entry;
      };
      const pop = () => {
        const result = heap[0];
        const tail = heap.pop();
        if (heap.length) {
          let index = 0;
          while (index * 2 + 1 < heap.length) {
            let child = index * 2 + 1;
            if (child + 1 < heap.length && heap[child + 1].priority < heap[child].priority) child++;
            if (heap[child].priority >= tail.priority) break;
            heap[index] = heap[child];
            index = child;
          }
          heap[index] = tail;
        }
        return result;
      };
      const heuristic = (identifier) => Math.abs(identifier % columns - end % columns) + Math.abs(Math.floor(identifier / columns) - Math.floor(end / columns));
      score[start] = 0;
      push({ identifier: start, priority: heuristic(start) });
      while (heap.length) {
        const { identifier } = pop();
        if (visited[identifier]) continue;
        visited[identifier] = 1;
        if (identifier === end) break;
        for (const offset of [-1, 1, -columns, columns]) {
          const next = identifier + offset;
          const horizontal = next % columns;
          const vertical = Math.floor(next / columns);
          if (horizontal < 1 || horizontal >= columns - 1 || vertical < 7 || vertical >= rows - 1) continue;
          if (next !== end && next !== start && blocked[next]) continue;
          const turn = previous[identifier] >= 0 && identifier - previous[identifier] !== offset ? 0.6 : 0;
          const candidate = score[identifier] + 1 + turn + (usage.get(next) ?? 0) * 3;
          if (candidate >= score[next]) continue;
          score[next] = candidate;
          previous[next] = identifier;
          push({ identifier: next, priority: candidate + heuristic(next) });
        }
      }
      if (previous[end] < 0 && start !== end) return undefined;
      const chain = [];
      for (let current = end; current >= 0; current = previous[current]) {
        chain.push([current % columns * grid, Math.floor(current / columns) * grid]);
        if (current === start) break;
      }
      return [startPort.face, ...chain.reverse(), endPort.face];
    };
    const chooseRoute = (source, target, blocked, edgeId) => {
      const ports = (rectangle) => [
        { x: rectangle.x - 10000, y: rectangle.y, width: rectangle.width, height: rectangle.height },
        { x: rectangle.x + 10000, y: rectangle.y, width: rectangle.width, height: rectangle.height },
        { x: rectangle.x, y: rectangle.y - 10000, width: rectangle.width, height: rectangle.height },
        { x: rectangle.x, y: rectangle.y + 10000, width: rectangle.width, height: rectangle.height },
      ].flatMap((destination) => {
        const centerPort = port(rectangle, destination);
        const horizontalSide = centerPort.face[1] === rectangle.y || centerPort.face[1] === rectangle.y + rectangle.height;
        return [0.5, 0.25, 0.75, 0.1, 0.9].map((fraction) => {
          const face = [...centerPort.face];
          const anchor = [...centerPort.anchor];
          const axis = horizontalSide ? 0 : 1;
          const origin = horizontalSide ? rectangle.x : rectangle.y;
          const extent = horizontalSide ? rectangle.width : rectangle.height;
          face[axis] = Math.round((origin + Math.max(20, Math.min(extent - 20, extent * fraction))) / grid) * grid;
          anchor[axis] = face[axis];
          return { face, anchor };
        });
      })
        .filter((candidate) => !blocked[candidate.anchor[1] / grid * columns + candidate.anchor[0] / grid]);
      const pairs = ports(source).flatMap((startPort) => ports(target).map((endPort) => ({
        startPort, endPort,
        distance: Math.abs(startPort.anchor[0] - endPort.anchor[0]) + Math.abs(startPort.anchor[1] - endPort.anchor[1]),
      }))).sort((left, right) => left.distance - right.distance);
      for (const { startPort, endPort } of pairs) {
        const points = route(startPort, endPort, blocked);
        if (points) return points;
      }
      throw new Error(`No clear connector ports: ${edgeId}`);
    };
    const compact = (points) => points.filter((point, index) => {
      if (index === 0 || index === points.length - 1) return true;
      const before = points[index - 1];
      const after = points[index + 1];
      return !((before[0] === point[0] && point[0] === after[0]) || (before[1] === point[1] && point[1] === after[1]));
    });
    const baseObstacles = [...nodeBoxes, ...headerObstacles];
    const labelBoxes = [];
    const edgeElements = [];
    const rectangles = { ...layout.nodes, ...layout.boundaries };
    const measurement = document.createElement('canvas').getContext('2d');
    measurement.font = "24px 'Segoe UI'";
    for (const edge of parsed.edges) {
      if (edge.arrow !== 'arrow_point' || !['normal', 'dotted'].includes(edge.stroke)) throw new Error(`Unsupported edge semantics: ${edge.id}`);
      const source = rectangles[edge.source];
      const target = rectangles[edge.target];
      const obstacles = [...baseObstacles, ...labelBoxes].filter((rectangle) => !(groupById[edge.target] && rectangle === headerObstacles[parsed.boundaries.indexOf(groupById[edge.target])]));
      const preliminary = chooseRoute(source, target, blockedGrid(baseObstacles), edge.id);
      const label = document.createElement('div');
      label.className = `edge-label ${edge.stroke === 'dotted' ? 'secondary' : ''}`;
      label.textContent = edge.label;
      label.dataset.edgeLabel = edge.id;
      label.style.width = `${Math.min(360, Math.max(150, Math.ceil(measurement.measureText(edge.label).width + 24)))}px`;
      sheet.append(label);
      const width = label.offsetWidth;
      const height = label.offsetHeight;
      const candidates = [];
      for (let index = 2; index < preliminary.length - 2; index++) {
        const [horizontal, vertical] = preliminary[index];
        const rectangle = { x: horizontal - width / 2, y: vertical - height / 2, width, height };
        if (rectangle.x < 25 || rectangle.x + width > 3815 || rectangle.y < 145 || rectangle.y + height > 2115) continue;
        if (obstacles.some((obstacle) => intersects(rectangle, obstacle, 32))) continue;
        candidates.push({ ...rectangle, score: Math.abs(index - preliminary.length / 2) });
      }
      if (!candidates.length) {
        for (let vertical = 160; vertical < 2090 - height; vertical += 40) {
          for (let horizontal = 40; horizontal < 3800 - width; horizontal += 40) {
            const rectangle = { x: horizontal, y: vertical, width, height };
            if (obstacles.some((obstacle) => intersects(rectangle, obstacle, 32))) continue;
            candidates.push({ ...rectangle, score: Math.min(...preliminary.map((point) => Math.abs(point[0] - horizontal - width / 2) + Math.abs(point[1] - vertical - height / 2))) });
          }
        }
      }
      if (!candidates.length) throw new Error(`No readable label space: ${edge.id}`);
      const rectangle = candidates.sort((left, right) => left.score - right.score)[0];
      setBox(label, rectangle);
      labelBoxes.push({ id: edge.id, ...rectangle });
      edgeElements.push({ edge, label, rectangle });
    }
    const allObstacles = [...baseObstacles, ...labelBoxes];
    const routes = [];
    for (const { edge, rectangle } of edgeElements) {
      const source = rectangles[edge.source];
      const target = rectangles[edge.target];
      const blocked = blockedGrid(allObstacles);
      const first = compact(chooseRoute(source, rectangle, blocked, `${edge.id}: source to label`));
      const second = compact(chooseRoute(rectangle, target, blocked, `${edge.id}: label to target`));
      const secondary = edge.stroke === 'dotted';
      const group = document.createElementNS(namespace, 'g');
      group.dataset.edge = JSON.stringify(edge);
      for (const [index, points] of [first, second].entries()) {
        const data = points.map((point, position) => `${position ? 'L' : 'M'}${point.join(',')}`).join(' ');
        const halo = document.createElementNS(namespace, 'path');
        halo.setAttribute('d', data);
        halo.setAttribute('fill', 'none');
        halo.setAttribute('stroke', '#fff');
        halo.setAttribute('stroke-width', '9');
        group.append(halo);
        const line = document.createElementNS(namespace, 'path');
        line.setAttribute('d', data);
        line.setAttribute('fill', 'none');
        line.setAttribute('stroke', secondary ? '#947437' : '#28648a');
        line.setAttribute('stroke-width', secondary ? '2.5' : '3');
        if (secondary) line.setAttribute('stroke-dasharray', '10 7');
        if (index === 1) line.setAttribute('marker-end', `url(#${secondary ? 'secondary' : 'solid'}-arrow)`);
        group.append(line);
        for (let segment = 1; segment < points.length; segment++) {
          const previous = points[segment - 1];
          const current = points[segment];
          const distance = Math.abs(current[0] - previous[0]) + Math.abs(current[1] - previous[1]);
          for (let offset = 0; offset <= distance; offset += grid) {
            const fraction = distance ? offset / distance : 0;
            const identifier = Math.round((previous[1] + (current[1] - previous[1]) * fraction) / grid) * columns + Math.round((previous[0] + (current[0] - previous[0]) * fraction) / grid);
            usage.set(identifier, (usage.get(identifier) ?? 0) + 1);
          }
        }
      }
      svg.append(group);
      routes.push({ id: edge.id, first, second, labelBox: rectangle });
    }
    const actual = {
      nodes: [...sheet.querySelectorAll('[data-node]')].map((element) => ({ ...JSON.parse(element.dataset.node), label: element.querySelector('.node-copy').textContent })),
      edges: [...sheet.querySelectorAll('[data-edge]')].map((element) => {
        const edge = JSON.parse(element.dataset.edge);
        return { ...edge, label: sheet.querySelector(`[data-edge-label="${edge.id}"]`).textContent };
      }),
      boundaries: [...sheet.querySelectorAll('[data-boundary]')].map((element) => ({ ...JSON.parse(element.dataset.boundary), label: element.querySelector('.boundary-title').textContent })),
    };
    return { actual, routes, officialIconInstances: sheet.querySelectorAll('[data-official-icon]').length, geometryChecks: { nodeOverlaps: 0, textOverflows: 0, boundaryMembershipMismatches: 0, labelOverlaps: 0 } };
  }, { contract, parsed, layout, images });
}

function compareInventory(expected, actual) {
  for (const section of ['nodes', 'edges', 'boundaries']) {
    const sort = (items) => [...items].sort((left, right) => left.id.localeCompare(right.id));
    assert.deepEqual(sort(actual[section]), sort(expected[section]), `Rendered ${section} differ from approved source`);
  }
}

function validateRoutes(slug, parsed, routes) {
  const layout = layouts[slug];
  const rectangles = { ...layout.nodes, ...layout.boundaries };
  const onBorder = ([horizontal, vertical], rectangle) => {
    const withinHorizontal = horizontal >= rectangle.x && horizontal <= rectangle.x + rectangle.width;
    const withinVertical = vertical >= rectangle.y && vertical <= rectangle.y + rectangle.height;
    return (withinHorizontal && [rectangle.y, rectangle.y + rectangle.height].includes(vertical))
      || (withinVertical && [rectangle.x, rectangle.x + rectangle.width].includes(horizontal));
  };
  assert.equal(routes.length, parsed.edges.length);
  for (const edge of parsed.edges) {
    const routed = routes.find((candidate) => candidate.id === edge.id);
    assert.ok(routed, `Missing routed edge: ${edge.id}`);
    assert.ok(onBorder(routed.first[0], rectangles[edge.source]), `Wrong source port: ${edge.id}`);
    assert.ok(onBorder(routed.first.at(-1), routed.labelBox), `Disconnected label entry: ${edge.id}`);
    assert.ok(onBorder(routed.second[0], routed.labelBox), `Disconnected label exit: ${edge.id}`);
    assert.ok(onBorder(routed.second.at(-1), rectangles[edge.target]), `Wrong arrow target: ${edge.id}`);
    for (const points of [routed.first, routed.second]) {
      for (let index = 1; index < points.length; index++) {
        const [startX, startY] = points[index - 1];
        const [endX, endY] = points[index];
        assert.ok(startX === endX || startY === endY, `Non-orthogonal route: ${edge.id}`);
        assert.ok(endX >= 0 && endX <= 3840 && endY >= 0 && endY <= 2160, `Clipped route: ${edge.id}`);
        for (const [nodeId, rectangle] of Object.entries(layout.nodes)) {
          const crosses = startX === endX
            ? startX > rectangle.x && startX < rectangle.x + rectangle.width && Math.max(startY, endY) > rectangle.y && Math.min(startY, endY) < rectangle.y + rectangle.height
            : startY > rectangle.y && startY < rectangle.y + rectangle.height && Math.max(startX, endX) > rectangle.x && Math.min(startX, endX) < rectangle.x + rectangle.width;
          assert.ok(!crosses, `Connector crosses node: ${edge.id}/${nodeId}`);
        }
      }
    }
  }
}

async function verifyExport(page, contract, parsed, manifest, inspection) {
  const recorded = manifest.diagrams.find((diagram) => diagram.slug === contract.slug);
  assert.ok(recorded, `Missing export record: ${contract.slug}`);
  assert.equal(recorded.sha256, contract.sha256);
  compareInventory(parsed, recorded.inventory);
  compareInventory(parsed, recorded.actual);
  validateRoutes(contract.slug, parsed, recorded.routes);
  const bytes = await readFile(path.join(root, recorded.file));
  assert.equal(digest(bytes), recorded.outputSha256, `PNG changed: ${recorded.file}`);
  const dimensions = await page.evaluate(async (encoded) => {
    const image = new Image();
    image.src = `data:image/png;base64,${encoded}`;
    await image.decode();
    return [image.naturalWidth, image.naturalHeight];
  }, bytes.toString('base64'));
  assert.deepEqual(dimensions, [3840, 2160]);
  const visual = inspection.diagrams.find((diagram) => diagram.file === recorded.file);
  assert.equal(visual?.sha256, recorded.outputSha256, `Visual inspection is missing or stale: ${recorded.file}`);
  console.log(`Verified PNG decode, dimensions, source/output hashes, exact inventory, routed endpoints, node clearance and recorded visual inspection: ${contract.slug}`);
}

async function main() {
  for (const contract of contracts) await lockedSource(contract);
  const { server, url } = await startAssetServer();
  let browser;
  try {
    browser = await puppeteer.launch({ headless: true });
    const page = await browser.newPage();
    await page.setViewport({ width: 3840, height: 2160, deviceScaleFactor: 1 });
    await page.goto(url);
    const inventoryOnly = process.argv.includes('--inventory');
    const verifyOnly = process.argv.includes('--verify');
    const assets = inventoryOnly ? undefined : await loadIcons();
    const manifestPath = path.join(scriptDirectory, 'render-diagrams.manifest.json');
    const existingManifest = verifyOnly ? JSON.parse(await readFile(manifestPath, 'utf8')) : undefined;
    const inspection = verifyOnly ? JSON.parse(await readFile(path.join(scriptDirectory, 'render-diagrams.qa.json'), 'utf8')) : undefined;
    if (verifyOnly) {
      for (const [name, sha256] of Object.entries(existingManifest.rendererHashes)) {
        assert.equal(digest(await readFile(path.join(scriptDirectory, name))), sha256, `Renderer changed; rerender required: ${name}`);
      }
    }
    const output = [];
    for (const contract of contracts) {
      const source = await lockedSource(contract);
      const parsed = await inventory(page, source);
      console.log(`${contract.slug}: ${parsed.nodes.length} nodes, ${parsed.edges.length} edges, ${parsed.boundaries.length} boundaries; SHA-256 verified`);
      if (verifyOnly) {
        await verifyExport(page, contract, parsed, existingManifest, inspection);
      } else if (!inventoryOnly) {
        const rendered = await draw(page, contract, parsed, assets.images);
        compareInventory(parsed, rendered.actual);
        validateRoutes(contract.slug, parsed, rendered.routes);
        const filename = `docs/diagrams/${contract.slug}-azure-architecture.png`;
        const bytes = await page.screenshot({ path: path.join(root, filename), type: 'png' });
        assert.equal(Buffer.from(bytes).subarray(1, 4).toString(), 'PNG');
        assert.equal(Buffer.from(bytes).readUInt32BE(16), 3840);
        assert.equal(Buffer.from(bytes).readUInt32BE(20), 2160);
        output.push({ ...contract, source: `docs/diagrams/${contract.slug}-azure-architecture.mmd`, file: filename,
          width: 3840, height: 2160, outputSha256: digest(bytes), inventory: parsed,
          fidelity: 'Exact parsed-source versus rendered-DOM inventory match', ...rendered });
        console.log(`Rendered ${filename} (3840 x 2160); exact inventory match`);
      }
      await lockedSource(contract);
    }
    if (!inventoryOnly && !verifyOnly) {
      const rendererFiles = ['render-diagrams.mjs', 'render-diagrams.layout.mjs', 'render-diagrams.assets.ps1'];
      const rendererHashes = Object.fromEntries(await Promise.all(rendererFiles.map(async (name) => [name, digest(await readFile(path.join(scriptDirectory, name)))])));
      await writeFile(manifestPath, `${JSON.stringify({
        schemaVersion: 1, status: 'Approved design, not live deployment evidence', rendererHashes,
        browser: await browser.version(), node: process.version, assets: assets.manifest,
        visualInspection: { record: '.github/scripts/render-diagrams.qa.json', rule: 'Valid only when inspected PNG hashes match; never inferred from automated checks' }, diagrams: output,
      }, null, 2)}\n`);
    }
  } finally {
    await browser?.close();
    await new Promise((resolve) => server.close(resolve));
  }
}

await main();
