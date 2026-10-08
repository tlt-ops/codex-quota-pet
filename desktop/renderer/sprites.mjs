export async function loadImage(url) {
  const image = new Image();
  image.src = url;
  await image.decode();
  return image;
}

/** Remove the connected neutral exterior while preserving enclosed white art. */
export function removeEdgeWhite(imageData) {
  const { width, height, data } = imageData;
  const total = width * height,
    visited = new Uint8Array(total),
    neutral = new Uint8Array(total),
    barrier = new Uint8Array(total),
    queue = new Int32Array(total);
  let head = 0,
    tail = 0;
  for (let index = 0; index < total; index++) {
    const offset = index * 4,
      r = data[offset],
      g = data[offset + 1],
      b = data[offset + 2];
    // The supplied PNG has a textured off-white background. Its soft gray
    // flecks fall below245; accepting only neutral colors keeps the lavender
    // hearts, sparkles and shadows separate from that background.
    neutral[index] =
      data[offset + 3] === 0 ||
      (Math.min(r, g, b) >= 235 && Math.max(r, g, b) - Math.min(r, g, b) <= 24)
        ? 1
        : 0;
  }
  // A one-pixel barrier closes tiny antialiased gaps in the ink outline.
  // Otherwise a more permissive background fill can reach the white hair.
  for (let index = 0; index < total; index++) {
    if (neutral[index]) continue;
    const x = index % width,
      y = Math.floor(index / width);
    for (let dy = -1; dy <= 1; dy++)
      for (let dx = -1; dx <= 1; dx++) {
        if (x + dx >= 0 && x + dx < width && y + dy >= 0 && y + dy < height)
          barrier[(y + dy) * width + x + dx] = 1;
      }
  }
  const push = (index, edgeSeed = false) => {
    if (visited[index] || !neutral[index] || (barrier[index] && !edgeSeed))
      return;
    visited[index] = 1;
    queue[tail++] = index;
  };
  for (let x = 0; x < width; x++) {
    push(x, true);
    push((height - 1) * width + x, true);
  }
  for (let y = 0; y < height; y++) {
    push(y * width, true);
    push(y * width + width - 1, true);
  }
  while (head < tail) {
    const index = queue[head++],
      x = index % width,
      y = Math.floor(index / width);
    if (x) push(index - 1);
    if (x + 1 < width) push(index + 1);
    if (y) push(index - width);
    if (y + 1 < height) push(index + width);
    data.fill(0, index * 4, index * 4 + 4);
  }
  // Trim the neutral one-pixel exterior fringe without propagating through
  // the protected outline gaps into the enclosed white regions.
  for (let index = 0; index < total; index++) {
    if (!neutral[index] || visited[index]) continue;
    const x = index % width,
      y = Math.floor(index / width);
    let exteriorNeighbor = false;
    for (let dy = -1; dy <= 1 && !exteriorNeighbor; dy++)
      for (let dx = -1; dx <= 1; dx++) {
        if (
          x + dx >= 0 &&
          x + dx < width &&
          y + dy >= 0 &&
          y + dy < height &&
          visited[(y + dy) * width + x + dx]
        ) {
          exteriorNeighbor = true;
          break;
        }
      }
    if (exteriorNeighbor) data.fill(0, index * 4, index * 4 + 4);
  }

  // Drawings in the source slightly cross the equal6×4 cell boundaries.
  // A neighboring cell can therefore leave a detached thin strip at a crop
  // edge. Keep every interior component (including authored accents), and
  // clear only small, narrow components actually clipped by an image edge.
  visited.fill(0);
  for (let start = 0; start < total; start++) {
    if (visited[start] || data[start * 4 + 3] === 0) continue;
    head = 0;
    tail = 0;
    let minX = width,
      maxX = -1,
      minY = height,
      maxY = -1,
      touchesEdge = false;
    const add = (index) => {
      if (visited[index] || data[index * 4 + 3] === 0) return;
      visited[index] = 1;
      queue[tail++] = index;
    };
    add(start);
    while (head < tail) {
      const index = queue[head++],
        x = index % width,
        y = Math.floor(index / width);
      minX = Math.min(minX, x);
      maxX = Math.max(maxX, x);
      minY = Math.min(minY, y);
      maxY = Math.max(maxY, y);
      touchesEdge ||= x === 0 || y === 0 || x === width - 1 || y === height - 1;
      if (x) add(index - 1);
      if (x + 1 < width) add(index + 1);
      if (y) add(index - width);
      if (y + 1 < height) add(index + width);
    }
    const componentWidth = maxX - minX + 1,
      componentHeight = maxY - minY + 1;
    const narrow =
      componentWidth <= Math.max(1, Math.floor(width * 0.035)) ||
      componentHeight <= Math.max(1, Math.floor(height * 0.035));
    // Measured left-edge remnants in this sheet are at most49×172 pixels in
    // a242×272 cell, with<=5001 opaque pixels. These are detached pieces of
    // the preceding character; right-edge authored hearts/bubbles stay intact.
    const precedingCellFragment =
      minX === 0 &&
      componentWidth <= width * 0.22 &&
      componentHeight <= height * 0.66 &&
      tail <= total * 0.08;
    if (
      (touchesEdge && narrow && tail <= total * 0.04) ||
      precedingCellFragment
    ) {
      for (let i = 0; i < tail; i++)
        data.fill(0, queue[i] * 4, queue[i] * 4 + 4);
    }
  }
  return imageData;
}

export async function loadSprites(url) {
  const source = await loadImage(url),
    sprites = [];
  for (let row = 0; row < 4; row++)
    for (let column = 0; column < 6; column++) {
      const x0 = Math.round((column * source.width) / 6),
        x1 = Math.round(((column + 1) * source.width) / 6);
      const y0 = Math.round((row * source.height) / 4),
        y1 = Math.round(((row + 1) * source.height) / 4);
      const canvas = document.createElement("canvas");
      canvas.width = x1 - x0;
      canvas.height = y1 - y0;
      const context = canvas.getContext("2d", { willReadFrequently: true });
      context.drawImage(
        source,
        x0,
        y0,
        canvas.width,
        canvas.height,
        0,
        0,
        canvas.width,
        canvas.height,
      );
      context.putImageData(
        removeEdgeWhite(
          context.getImageData(0, 0, canvas.width, canvas.height),
        ),
        0,
        0,
      );
      sprites.push(canvas);
    }
  return sprites;
}
